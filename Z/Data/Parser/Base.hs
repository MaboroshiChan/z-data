{-|
Module      : Z.Data.Parser.Base
Description : Efficient deserialization/parse.
Copyright   : (c) Dong Han, 2017-2019
License     : BSD
Maintainer  : winterland1989@gmail.com
Stability   : experimental
Portability : non-portable

This module provide internal data types for a simple resumable 'Parser', which is suitable for binary protocol and simple textual protocol parsing. 'Parser' extensively works on on 'V.Bytes', which is same to 'T.Text' representation.

-}

module Z.Data.Parser.Base
  ( -- * Parser types
    Result(..)
  , ParseError
  , ParseStep
  , Parser(..)
  , (<?>)
    -- * Running a parser
  , parse, parse', parseChunk, ParseChunks, parseChunks, finishParsing
  , runAndKeepTrack, match
    -- * Basic parsers
  , ensureN, endOfInput, atEnd
    -- * Primitive decoders
  , decodePrim, BE(..), LE(..)
  , decodePrimLE, decodePrimBE
    -- * More parsers
  , scan, scanChunks, peekMaybe, peek, satisfy, satisfyWith
  , anyWord8, word8, char8, anyChar8, anyCharUTF8, charUTF8, char7, anyChar7
  , skipWord8, endOfLine, skip, skipWhile, skipSpaces
  , take, takeN, takeTill, takeWhile, takeWhile1, takeRemaining, bytes, bytesCI
  , text
    -- * Misc
  , fail'
  ) where

import           Control.Applicative
import           Control.Monad
import qualified Control.Monad.Fail                 as Fail
import qualified Data.CaseInsensitive               as CI
import qualified Data.Primitive.PrimArray           as A
import           Data.Int
import           Data.Word
import           Data.Bits                          ((.&.))
import           GHC.Types
import           Prelude                            hiding (take, takeWhile)
import           Z.Data.Array.Unaligned
import           Z.Data.ASCII
import qualified Z.Data.Text.Base                   as T
import qualified Z.Data.Text.Extra                  as T
import qualified Z.Data.Text.UTF8Codec              as T
import qualified Z.Data.Vector.Base                 as V
import qualified Z.Data.Vector.Extra                as V

-- | Simple parsing result, that represent respectively:
--
-- * Success: the remaining unparsed data and the parsed value
--
-- * Failure: the remaining unparsed data and the error message
--
-- * Partial: that need for more input data, supply empty bytes to indicate 'endOfInput'
--
data Result a
    = Success a          !V.Bytes
    | Failure ParseError !V.Bytes
    | Partial (ParseStep a)

-- | A parse step consumes 'V.Bytes' and produce 'Result'.
type ParseStep r = V.Bytes -> Result r

-- | Type alias for error message
type ParseError = [T.Text]

instance Functor Result where
    fmap f (Success a s)   = Success (f a) s
    fmap f (Partial k)     = Partial (fmap f . k)
    fmap _ (Failure e v)   = Failure e v

instance Show a => Show (Result a) where
    show (Success a _)    = "Success " ++ show a
    show (Partial _)      = "Partial _"
    show (Failure errs _) = "Failure: " ++ show errs


-- | Simple CPSed parser
--
-- A parser takes a failure continuation, and a success one, while the success continuation is
-- usually composed by 'Monad' instance, the failure one is more like a reader part, which can
-- be modified via '<?>'. If you build parsers from ground, a pattern like this can be used:
--
--  @
--    xxParser = do
--      ensureN errMsg ...            -- make sure we have some bytes
--      Parser $ \ kf k inp ->        -- fail continuation, success continuation and input
--        ...
--        ... kf errMsg (if input not OK)
--        ... k ... (if we get something useful for next parser)
--  @
newtype Parser a = Parser {
        runParser :: forall r . (ParseError -> ParseStep r) -> (a -> ParseStep r) -> ParseStep r
    }

-- It seems eta-expand all params to ensure parsers are saturated is helpful
instance Functor Parser where
    fmap f (Parser pa) = Parser (\ kf k inp -> pa kf (k . f) inp)
    {-# INLINE fmap #-}
    a <$ Parser pb = Parser (\ kf k inp -> pb kf (\ _ -> k a) inp)
    {-# INLINE (<$) #-}

instance Applicative Parser where
    pure x = Parser (\ _ k inp -> k x inp)
    {-# INLINE pure #-}
    Parser pf <*> Parser pa = Parser (\ kf k inp -> pf kf (\ f -> pa kf (k . f)) inp)
    {-# INLINE (<*>) #-}
    Parser pa *> Parser pb = Parser (\ kf k inp -> pa kf (\ _ inp' -> pb kf k inp') inp)
    {-# INLINE (*>) #-}
    Parser pa <* Parser pb = Parser (\ kf k inp -> pa kf (\ x inp' -> pb kf (\ _ -> k x) inp') inp)
    {-# INLINE (<*) #-}

instance Monad Parser where
    return = pure
    {-# INLINE return #-}
    Parser pa >>= f = Parser (\ kf k inp -> pa kf (\ a -> runParser (f a) kf k) inp)
    {-# INLINE (>>=) #-}
    (>>) = (*>)
    {-# INLINE (>>) #-}

instance Fail.MonadFail Parser where
    fail = fail' . T.pack
    {-# INLINE fail #-}

instance MonadPlus Parser where
    mzero = empty
    {-# INLINE mzero #-}
    mplus = (<|>)
    {-# INLINE mplus #-}

instance Alternative Parser where
    empty = fail' "Z.Data.Parser.Base(Alternative).empty"
    {-# INLINE empty #-}
    f <|> g = do
        (r, bss) <- runAndKeepTrack f
        case r of
            Success x inp   -> Parser (\ _ k _ -> k x inp)
            Failure _ _     -> let !bs = V.concat (reverse bss)
                               in Parser (\ kf k _ -> runParser g kf k bs)
            _               -> error "Z.Data.Parser.Base: impossible"
    {-# INLINE (<|>) #-}

-- | 'T.Text' version of 'fail'.
fail' :: T.Text -> Parser a
{-# INLINE fail' #-}
fail' msg = Parser (\ kf _ inp -> kf [msg] inp)

-- | Parse the complete input, without resupplying
parse' :: Parser a -> V.Bytes -> Either ParseError a
{-# INLINE parse' #-}
parse' (Parser p) inp = snd $ finishParsing (p Failure Success inp)

-- | Parse the complete input, without resupplying, return the rest bytes
parse :: Parser a -> V.Bytes -> (V.Bytes, Either ParseError a)
{-# INLINE parse #-}
parse (Parser p) inp = finishParsing (p Failure Success inp)

-- | Parse an input chunk
parseChunk :: Parser a -> V.Bytes -> Result a
{-# INLINE parseChunk #-}
parseChunk (Parser p) = p Failure Success

-- | Finish parsing and fetch result, feed empty bytes if it's 'Partial' result.
finishParsing :: Result a -> (V.Bytes, Either ParseError a)
{-# INLINABLE finishParsing #-}
finishParsing r = case r of
    Success a rest    -> (rest, Right a)
    Failure errs rest -> (rest, Left errs)
    Partial f         -> finishParsing (f V.empty)

-- | Type alias for a streaming parser, draw chunk from Monad m (with a initial chunk), return result in @Either err x@.
type ParseChunks m chunk err x = m chunk -> chunk -> m (chunk, Either err x)

-- | Run a parser with an initial input string, and a monadic action
-- that can supply more input if needed.
--
-- Note, once the monadic action return empty bytes, parsers will stop drawing
-- more bytes (take it as 'endOfInput').
parseChunks :: Monad m => Parser a -> ParseChunks m V.Bytes ParseError a
{-# INLINABLE parseChunks #-}
parseChunks (Parser p) m0 inp = go m0 (p Failure Success inp)
  where
    go m r = case r of
        Partial f -> do
            inp' <- m
            if V.null inp'
            then go (pure V.empty) (f V.empty)
            else go m (f inp')
        Success a rest    -> pure (rest, Right a)
        Failure errs rest -> pure (rest, Left errs)

(<?>) :: T.Text -> Parser a -> Parser a
{-# INLINE (<?>) #-}
msg <?> (Parser p) = Parser (\ kf k inp -> p (kf . (msg:)) k inp)
infixr 0 <?>

-- | Run a parser and keep track of all the input chunks it consumes.
-- Once it's finished, return the final result (always 'Success' or 'Failure') and
-- all consumed chunks.
--
runAndKeepTrack :: Parser a -> Parser (Result a, [V.Bytes])
{-# INLINE runAndKeepTrack #-}
runAndKeepTrack (Parser pa) = Parser $ \ _ k0 inp ->
    let go !acc r k = case r of
            Partial k'      -> Partial (\ inp' -> go (inp':acc) (k' inp') k)
            Success _ inp' -> k (r, reverse acc) inp'
            Failure _ inp' -> k (r, reverse acc) inp'
        r0 = pa Failure Success inp
    in go [inp] r0 k0

-- | Return both the result of a parse and the portion of the input
-- that was consumed while it was being parsed.
match :: Parser a -> Parser (V.Bytes, a)
{-# INLINE match #-}
match p = do
    (r, bss) <- runAndKeepTrack p
    Parser (\ _ k _ ->
        case r of
            Success r' inp'  -> let !consumed = V.dropR (V.length inp') (V.concat (reverse bss))
                                in k (consumed , r') inp'
            Failure err inp' -> Failure err inp'
            Partial _        -> error "Z.Data.Parser.Base.match: impossible")

-- | Ensure that there are at least @n@ bytes available. If not, the
-- computation will escape with 'Partial'.
--
-- Since this parser is used in many other parsers, an extra error param is provide
-- to attach custom error info.
ensureN :: Int -> ParseError -> Parser ()
{-# INLINE ensureN #-}
ensureN n0 err = Parser $ \ kf k inp -> do
    let l = V.length inp
    if l >= n0
    then k () inp
    else Partial (ensureNPartial l inp kf k)
  where
    {-# INLINABLE ensureNPartial #-}
    ensureNPartial :: forall r. Int -> V.PrimVector Word8 -> (ParseError -> ParseStep r) -> (() -> ParseStep r) -> ParseStep r
    ensureNPartial l0 inp0 kf k =
        let go acc !l = \ inp -> do
                let l' = V.length inp
                if l' == 0
                then kf err (V.concat (reverse (inp:acc)))
                else do
                    let l'' = l + l'
                    if l'' < n0
                    then Partial (go (inp:acc) l'')
                    else
                        let !inp' = V.concat (reverse (inp:acc))
                        in k () inp'
        in go [inp0] l0

-- | Test whether all input has been consumed, i.e. there are no remaining
-- undecoded bytes. Fail if not 'atEnd'.
endOfInput :: Parser ()
{-# INLINE endOfInput #-}
endOfInput = Parser $ \ kf k inp ->
    if V.null inp
    then Partial (\ inp' ->
        if (V.null inp')
        then k () inp'
        else kf ["Z.Data.Parser.Base.endOfInput: end not reached yet"] inp)
    else kf ["Z.Data.Parser.Base.endOfInput: end not reached yet"] inp

-- | Test whether all input has been consumed, i.e. there are no remaining
-- undecoded bytes.
atEnd :: Parser Bool
{-# INLINE atEnd #-}
atEnd = Parser $ \ _ k inp ->
    if V.null inp
    then Partial (\ inp' -> k (V.null inp') inp')
    else k False inp

-- | Decode a primitive type in host byte order.
decodePrim :: forall a. (Unaligned a) => Parser a
{-# INLINE decodePrim #-}
{-# SPECIALIZE INLINE decodePrim :: Parser Word   #-}
{-# SPECIALIZE INLINE decodePrim :: Parser Word64 #-}
{-# SPECIALIZE INLINE decodePrim :: Parser Word32 #-}
{-# SPECIALIZE INLINE decodePrim :: Parser Word16 #-}
{-# SPECIALIZE INLINE decodePrim :: Parser Word8  #-}
{-# SPECIALIZE INLINE decodePrim :: Parser Int   #-}
{-# SPECIALIZE INLINE decodePrim :: Parser Int64 #-}
{-# SPECIALIZE INLINE decodePrim :: Parser Int32 #-}
{-# SPECIALIZE INLINE decodePrim :: Parser Int16 #-}
{-# SPECIALIZE INLINE decodePrim :: Parser Int8  #-}
{-# SPECIALIZE INLINE decodePrim :: Parser Double #-}
{-# SPECIALIZE INLINE decodePrim :: Parser Float #-}
decodePrim = do
    ensureN n ["Z.Data.Parser.Base.decodePrim: not enough bytes"]
    Parser (\ _ k (V.PrimVector ba i len) ->
        let !r = indexPrimWord8ArrayAs ba i
        in k r (V.PrimVector ba (i+n) (len-n)))
  where
    n = getUnalignedSize (unalignedSize @a)

-- | Decode a primitive type in little endian.
decodePrimLE :: forall a. (Unaligned (LE a)) => Parser a
{-# INLINE decodePrimLE #-}
{-# SPECIALIZE INLINE decodePrimLE :: Parser Word   #-}
{-# SPECIALIZE INLINE decodePrimLE :: Parser Word64 #-}
{-# SPECIALIZE INLINE decodePrimLE :: Parser Word32 #-}
{-# SPECIALIZE INLINE decodePrimLE :: Parser Word16 #-}
{-# SPECIALIZE INLINE decodePrimLE :: Parser Int   #-}
{-# SPECIALIZE INLINE decodePrimLE :: Parser Int64 #-}
{-# SPECIALIZE INLINE decodePrimLE :: Parser Int32 #-}
{-# SPECIALIZE INLINE decodePrimLE :: Parser Int16 #-}
{-# SPECIALIZE INLINE decodePrimLE :: Parser Double #-}
{-# SPECIALIZE INLINE decodePrimLE :: Parser Float #-}
decodePrimLE = do
    ensureN n ["Z.Data.Parser.Base.decodePrimLE: not enough bytes"]
    Parser (\ _ k (V.PrimVector ba i len) ->
        let !r = indexPrimWord8ArrayAs ba i
        in k (getLE r) (V.PrimVector ba (i+n) (len-n)))
  where
    n = getUnalignedSize (unalignedSize @(LE a))

-- | Decode a primitive type in big endian.
decodePrimBE :: forall a. (Unaligned (BE a)) => Parser a
{-# INLINE decodePrimBE #-}
{-# SPECIALIZE INLINE decodePrimBE :: Parser Word   #-}
{-# SPECIALIZE INLINE decodePrimBE :: Parser Word64 #-}
{-# SPECIALIZE INLINE decodePrimBE :: Parser Word32 #-}
{-# SPECIALIZE INLINE decodePrimBE :: Parser Word16 #-}
{-# SPECIALIZE INLINE decodePrimBE :: Parser Int   #-}
{-# SPECIALIZE INLINE decodePrimBE :: Parser Int64 #-}
{-# SPECIALIZE INLINE decodePrimBE :: Parser Int32 #-}
{-# SPECIALIZE INLINE decodePrimBE :: Parser Int16 #-}
{-# SPECIALIZE INLINE decodePrimBE :: Parser Double #-}
{-# SPECIALIZE INLINE decodePrimBE :: Parser Float #-}
decodePrimBE = do
    ensureN n ["Z.Data.Parser.Base.decodePrimBE: not enough bytes"]
    Parser (\ _ k (V.PrimVector ba i len) ->
        let !r = indexPrimWord8ArrayAs ba i
        in k (getBE r) (V.PrimVector ba (i+n) (len-n)))
  where
    n = getUnalignedSize (unalignedSize @(BE a))

-- | A stateful scanner.  The predicate consumes and transforms a
-- state argument, and each transformed state is passed to successive
-- invocations of the predicate on each byte of the input until one
-- returns 'Nothing' or the input ends.
--
-- This parser does not fail.  It will return an empty string if the
-- predicate returns 'Nothing' on the first byte of input.
--
scan :: s -> (s -> Word8 -> Maybe s) -> Parser (V.Bytes, s)
{-# INLINE scan #-}
scan s0 f = scanChunks s0 f'
  where
    f' s0' (V.PrimVector arr off l) =
        let !end = off + l
            go !st !i
                | i < end = do
                    let !w = A.indexPrimArray arr i
                    case f st w of
                        Just st' -> go st' (i+1)
                        _        ->
                            let !len1 = i - off
                                !len2 = end - off
                            in Right (V.PrimVector arr off len1, V.PrimVector arr i len2, st)
                | otherwise = Left st
        in go s0' off

-- | Similar to 'scan', but working on 'V.Bytes' chunks, The predicate
-- consumes a 'V.Bytes' chunk and transforms a state argument,
-- and each transformed state is passed to successive invocations of
-- the predicate on each chunk of the input until one chunk got splited to
-- @Right (V.Bytes, V.Bytes)@ or the input ends.
--
scanChunks :: forall s. s -> (s -> V.Bytes -> Either s (V.Bytes, V.Bytes, s)) -> Parser (V.Bytes, s)
{-# INLINE scanChunks #-}
scanChunks s0 consume = Parser (\ _ k inp ->
    case consume s0 inp of
        Right (want, rest, s') -> k (want, s') rest
        Left s' -> Partial (scanChunksPartial s' k inp))
  where
    -- we want to inline consume if possible
    {-# INLINABLE scanChunksPartial #-}
    scanChunksPartial :: forall r. s -> ((V.PrimVector Word8, s) -> ParseStep r) -> V.PrimVector Word8 -> ParseStep r
    scanChunksPartial s0' k inp0 =
        let go s acc = \ inp ->
                if V.null inp
                then k (V.concat (reverse acc), s) inp
                else case consume s inp of
                        Left s' -> do
                            let acc' = inp : acc
                            Partial (go s' acc')
                        Right (want,rest,s') ->
                            let !r = V.concat (reverse (want:acc)) in k (r, s') rest
        in go s0' [inp0]

--------------------------------------------------------------------------------

-- | Match any byte, to perform lookahead. Returns 'Nothing' if end of
-- input has been reached. Does not consume any input.
--
peekMaybe :: Parser (Maybe Word8)
{-# INLINE peekMaybe #-}
peekMaybe =
    Parser $ \ _ k inp ->
        if V.null inp
        then Partial (\ inp' -> k (if V.null inp'
            then Nothing
            else Just (V.unsafeHead inp)) inp')
        else k (Just (V.unsafeHead inp)) inp

-- | Match any byte, to perform lookahead.  Does not consume any
-- input, but will fail if end of input has been reached.
--
peek :: Parser Word8
{-# INLINE peek #-}
peek =
    Parser $ \ kf k inp ->
        if V.null inp
        then Partial (\ inp' ->
            if V.null inp'
            then kf ["Z.Data.Parser.Base.peek: not enough bytes"] inp'
            else k (V.unsafeHead inp') inp')
        else k (V.unsafeHead inp) inp

-- | The parser @satisfy p@ succeeds for any byte for which the
-- predicate @p@ returns 'True'. Returns the byte that is actually
-- parsed.
--
-- >digit = satisfy isDigit
-- >    where isDigit w = w >= 48 && w <= 57
--
satisfy :: (Word8 -> Bool) -> Parser Word8
{-# INLINE satisfy #-}
satisfy p = do
    ensureN 1 ["Z.Data.Parser.Base.satisfy: not enough bytes"]
    Parser $ \ kf k inp ->
        let w = V.unsafeHead inp
        in if p w
            then k w (V.unsafeTail inp)
            else kf ["Z.Data.Parser.Base.satisfy: unsatisfied byte"] (V.unsafeTail inp)

-- | The parser @satisfyWith f p@ transforms a byte, and succeeds if
-- the predicate @p@ returns 'True' on the transformed value. The
-- parser returns the transformed byte that was parsed.
--
satisfyWith :: (Word8 -> a) -> (a -> Bool) -> Parser a
{-# INLINE satisfyWith #-}
satisfyWith f p = do
    ensureN 1 ["Z.Data.Parser.Base.satisfyWith: not enough bytes"]
    Parser $ \ kf k inp ->
        let a = f (V.unsafeHead inp)
        in if p a
            then k a (V.unsafeTail inp)
            else kf ["Z.Data.Parser.Base.satisfyWith: unsatisfied byte"] (V.unsafeTail inp)

-- | Match a specific byte.
--
word8 :: Word8 -> Parser ()
{-# INLINE word8 #-}
word8 w' = do
    ensureN 1 ["Z.Data.Parser.Base.word8: not enough bytes"]
    Parser (\ kf k inp ->
        let w = V.unsafeHead inp
        in if w == w'
            then k () (V.unsafeTail inp)
            else kf ["Z.Data.Parser.Base.word8: mismatch byte"] inp)

-- | Return a byte, this is an alias to @decodePrim @Word8@.
--
anyWord8 :: Parser Word8
{-# INLINE anyWord8 #-}
anyWord8 = decodePrim

-- | Match a specific 8bit char.
--
char8 :: Char -> Parser ()
{-# INLINE char8 #-}
char8 = word8 . c2w

-- | Match a specific 7bit char.
--
char7 :: Char -> Parser ()
{-# INLINE char7 #-}
char7 chr = word8 (c2w chr .&. 0x7F)

-- | Match a specific UTF8 char.
--
charUTF8 :: Char -> Parser ()
{-# INLINE charUTF8 #-}
charUTF8 = text . T.singleton

-- | Take a byte and return as a 8bit char.
--
anyChar8 :: Parser Char
{-# INLINE anyChar8 #-}
anyChar8 = do
    w <- anyWord8
    return $! w2c w

-- | Take a byte and return as a 7bit char, fail if exceeds @0x7F@.
--
anyChar7 :: Parser Char
{-# INLINE anyChar7 #-}
anyChar7 = do
    w <- anyWord8
    if w > 0x7f
    then fail' "Z.Data.Parser.anyChar7: byte exceeds 0x7F"
    else return $! w2c w

-- | Decode next few bytes as an UTF8 char.
--
-- Don't use this method as UTF8 decoder, it's slower than 'T.validate'.
anyCharUTF8 :: Parser Char
{-# INLINABLE anyCharUTF8 #-}
anyCharUTF8 = do
    r <- Parser $ \ kf k inp -> do
        let (V.PrimVector arr s l) = inp
        if l > 0
        then
            let l' = T.decodeCharLen arr s
            in if l' > l
            then k (Left l') inp
            else do
                case T.validateMaybe (V.unsafeTake l' inp) of
                    Just t -> k (Right $! T.head t) $! V.unsafeDrop l' inp
                    _ -> kf ["Z.Data.Parser.Base.anyCharUTF8: invalid UTF8 bytes"] inp
        else k (Left 1) inp
    case r of
        Left d -> do
            ensureN d ["Z.Data.Parser.Base.anyCharUTF8: not enough bytes"]
            anyCharUTF8
        Right c -> return c

-- | Match either a single newline byte @\'\\n\'@, or a carriage
-- return followed by a newline byte @\"\\r\\n\"@.
endOfLine :: Parser ()
{-# INLINE endOfLine #-}
endOfLine = do
    w <- decodePrim :: Parser Word8
    case w of
        10 -> return ()
        13 -> word8 10
        _  -> fail' "Z.Data.Parser.Base.endOfLine: mismatch byte"

--------------------------------------------------------------------------------

-- | 'skip' N bytes.
--
skip :: Int -> Parser ()
{-# INLINE skip #-}
skip n =
    Parser (\ kf k inp ->
        let l = V.length inp
            !n' = max n 0
        in if l >= n'
            then k () $! V.unsafeDrop n' inp
            else Partial (skipPartial (n'-l) kf k))

skipPartial :: Int -> (ParseError -> ParseStep r) -> (() -> ParseStep r) -> ParseStep r
{-# INLINABLE skipPartial #-}
skipPartial n kf k =
    let go !n' = \ inp ->
            let l = V.length inp
            in if l >= n'
                then k () $! V.unsafeDrop n' inp
                else if l == 0
                    then kf ["Z.Data.Parser.Base.skip: not enough bytes"] inp
                    else Partial (go (n'-l))
    in go n

-- | Skip a byte.
--
skipWord8 :: Parser ()
{-# INLINE skipWord8 #-}
skipWord8 =
    Parser $ \ kf k inp ->
        if V.null inp
        then Partial (\ inp' ->
            if V.null inp'
            then kf ["Z.Data.Parser.Base.skipWord8: not enough bytes"] inp'
            else k () (V.unsafeTail inp'))
        else k () (V.unsafeTail inp)

-- | Skip past input for as long as the predicate returns 'True'.
--
skipWhile :: (Word8 -> Bool) -> Parser ()
{-# INLINE skipWhile #-}
skipWhile p =
    Parser (\ _ k inp ->
        let rest = V.dropWhile p inp
        in if V.null rest
            then Partial (skipWhilePartial k)
            else k () rest)
  where
    -- we want to inline p if possible
    {-# INLINABLE skipWhilePartial #-}
    skipWhilePartial :: forall r. (() -> ParseStep r) -> ParseStep r
    skipWhilePartial k =
        let go = \ inp ->
                if V.null inp
                then k () inp
                else
                    let !rest = V.dropWhile p inp
                    in if V.null rest then Partial go else k () rest
        in go

-- | Skip over white space using 'isSpace'.
--
skipSpaces :: Parser ()
{-# INLINE skipSpaces #-}
skipSpaces = skipWhile isSpace

take :: Int -> Parser V.Bytes
{-# INLINE take #-}
take n = do
    -- we use unsafe slice, guard negative n here
    ensureN n' ["Z.Data.Parser.Base.take: not enough bytes"]
    Parser (\ _ k inp ->
        let !r = V.unsafeTake n' inp
            !inp' = V.unsafeDrop n' inp
        in k r inp')
  where !n' = max 0 n

-- | Consume input as long as the predicate returns 'False' or reach the end of input,
-- and return the consumed input.
--
takeTill :: (Word8 -> Bool) -> Parser V.Bytes
{-# INLINE takeTill #-}
takeTill p = Parser (\ _ k inp ->
    let (want, rest) = V.break p inp
    in if V.null rest
        then Partial (takeTillPartial k want)
        else k want rest)
  where
    {-# INLINABLE takeTillPartial #-}
    takeTillPartial :: forall r. (V.PrimVector Word8 -> ParseStep r) -> V.PrimVector Word8 -> ParseStep r
    takeTillPartial k want =
        let go acc = \ inp ->
                if V.null inp
                then let !r = V.concat (reverse acc) in k r inp
                else
                    let (want', rest) = V.break p inp
                        acc' = want' : acc
                    in if V.null rest
                        then Partial (go acc')
                        else let !r = V.concat (reverse acc') in k r rest
        in go [want]

-- | Consume input as long as the predicate returns 'True' or reach the end of input,
-- and return the consumed input.
--
takeWhile :: (Word8 -> Bool) -> Parser V.Bytes
{-# INLINE takeWhile #-}
takeWhile p = Parser (\ _ k inp ->
    let (want, rest) = V.span p inp
    in if V.null rest
        then Partial (takeWhilePartial k want)
        else k want rest)
  where
    -- we want to inline p if possible
    {-# INLINABLE takeWhilePartial #-}
    takeWhilePartial :: forall r. (V.PrimVector Word8 -> ParseStep r) -> V.PrimVector Word8 -> ParseStep r
    takeWhilePartial k want =
        let go acc = \ inp ->
                if V.null inp
                then let !r = V.concat (reverse acc) in k r inp
                else
                    let (want', rest) = V.span p inp
                        acc' = want' : acc
                    in if V.null rest
                        then Partial (go acc')
                        else let !r = V.concat (reverse acc') in k r rest
        in go [want]

-- | Similar to 'takeWhile', but requires the predicate to succeed on at least one byte
-- of input: it will fail if the predicate never returns 'True' or reach the end of input
--
takeWhile1 :: (Word8 -> Bool) -> Parser V.Bytes
{-# INLINE takeWhile1 #-}
takeWhile1 p = do
    bs <- takeWhile p
    if V.null bs
    then fail' "Z.Data.Parser.Base.takeWhile1: no satisfied byte"
    else return bs

-- | Take all the remaining input chunks and return as 'V.Bytes'.
takeRemaining :: Parser V.Bytes
{-# INLINE takeRemaining #-}
takeRemaining = Parser (\ _ k inp -> Partial (takeRemainingPartial k inp))
  where
    {-# INLINABLE takeRemainingPartial #-}
    takeRemainingPartial :: forall r. (V.PrimVector Word8 -> ParseStep r) -> V.PrimVector Word8 -> ParseStep r
    takeRemainingPartial k want =
        let go acc = \ inp ->
                if V.null inp
                then let !r = V.concat (reverse acc) in k r inp
                else let acc' = inp : acc in Partial (go acc')
        in go [want]

-- | Similar to 'take', but requires the predicate to succeed on next N bytes
-- of input, and take N bytes(no matter if N+1 byte satisfy predicate or not).
--
takeN :: (Word8 -> Bool) -> Int -> Parser V.Bytes
{-# INLINE takeN #-}
takeN p n = do
    bs <- take n
    if go bs 0
    then return bs
    else fail' "Z.Data.Parser.Base.takeWhileN: byte does not satisfy"
  where
    go bs@(V.PrimVector _ _ l) !i
        | i < l = p (V.unsafeIndex bs i) && go bs (i+1)
        | otherwise = True

-- | @bytes s@ parses a sequence of bytes that identically match @s@.
--
bytes :: V.Bytes -> Parser ()
{-# INLINE bytes #-}
bytes bs = do
    let n = V.length bs
    ensureN n ["Z.Data.Parser.Base.bytes: not enough bytes"]
    Parser (\ kf k inp ->
        if bs == V.unsafeTake n inp
        then k () $! V.unsafeDrop n inp
        else kf ["Z.Data.Parser.Base.bytes: mismatch bytes"] inp)


-- | Same as 'bytes' but ignoring ASCII case.
bytesCI :: V.Bytes -> Parser ()
{-# INLINE bytesCI #-}
bytesCI bs = do
    let n = V.length bs
    -- casefold an ASCII string should not change it's length
    ensureN n ["Z.Data.Parser.Base.bytesCI: not enough bytes"]
    Parser (\ kf k inp ->
        if bs' == CI.foldCase (V.unsafeTake n inp)
        then k () $! V.unsafeDrop n inp
        else kf ["Z.Data.Parser.Base.bytesCI: mismatch bytes"] inp)
  where
    bs' = CI.foldCase bs

-- | @text s@ parses a sequence of UTF8 bytes that identically match @s@.
--
text :: T.Text -> Parser ()
{-# INLINE text #-}
text (T.Text bs) = bytes bs
