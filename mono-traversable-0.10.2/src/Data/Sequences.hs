{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ConstraintKinds #-}
-- | Warning: This module should be considered highly experimental.
module Data.Sequences where

import Data.Maybe (fromJust, isJust)
import Data.Monoid (Monoid, mappend, mconcat, mempty)
import Data.MonoTraversable
import Data.Int (Int64, Int)
import qualified Data.List as List
import qualified Data.List.Split as List
import qualified Control.Monad (filterM, replicateM)
import Prelude (Bool (..), Monad (..), Maybe (..), Ordering (..), Ord (..), Eq (..), Functor (..), fromIntegral, otherwise, (-), fst, snd, Integral, ($), flip, maybe, error)
import Data.Char (Char, isSpace)
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Control.Category
import Control.Arrow ((***), first, second)
import Control.Monad (liftM)
import qualified Data.Sequence as Seq
import qualified Data.DList as DList
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Storable as VS
import Data.String (IsString)
import qualified Data.List.NonEmpty as NE
import qualified Data.ByteString.Unsafe as SU
import Data.GrowingAppend
import Data.Vector.Instances ()
import qualified Data.Vector.Generic as VG
import qualified Data.Vector.Algorithms.Merge as VAM
import Data.Ord (comparing)

-- | 'SemiSequence' was created to share code between 'IsSequence' and 'MinLen'.
--
-- @Semi@ means 'SemiGroup'
-- A 'SemiSequence' can accomodate a 'SemiGroup' such as 'NonEmpty' or 'MinLen'
-- A Monoid should be able to fill out 'IsSequence'.
--
-- 'SemiSequence' operations maintain the same type because they all maintain the same number of elements or increase them.
-- However, a decreasing function such as filter may change they type.
-- For example, from 'NonEmpty' to '[]'
-- This type-changing function exists on 'NonNull' as 'nfilter'
--
-- 'filter' and other such functions are placed in 'IsSequence'
class (Integral (Index seq), GrowingAppend seq) => SemiSequence seq where
    -- | The type of the index of a sequence.
    type Index seq

    -- | 'intersperse' takes an element and intersperses that element between
    -- the elements of the sequence.
    --
    -- @
    -- > 'intersperse' ',' "abcde"
    -- "a,b,c,d,e"
    -- @
    intersperse :: Element seq -> seq -> seq

    -- | Reverse a sequence
    --
    -- @
    -- > 'reverse' "hello world"
    -- "dlrow olleh"
    -- @
    reverse :: seq -> seq

    -- | 'find' takes a predicate and a sequence and returns the first element in
    -- the sequence matching the predicate, or 'Nothing' if there isn't an element
    -- that matches the predicate.
    --
    -- @
    -- > 'find' (== 5) [1 .. 10]
    -- 'Just' 5
    --
    -- > 'find' (== 15) [1 .. 10]
    -- 'Nothing'
    -- @
    find :: (Element seq -> Bool) -> seq -> Maybe (Element seq)

    -- | Sort a sequence using an supplied element ordering function.
    --
    -- @
    -- > let compare' x y = case 'compare' x y of LT -> GT; EQ -> EQ; GT -> LT
    -- > 'sortBy' compare' [5,3,6,1,2,4]
    -- [6,5,4,3,2,1]
    -- @
    sortBy :: (Element seq -> Element seq -> Ordering) -> seq -> seq

    -- | Prepend an element onto a sequence.
    --
    -- @
    -- > 4 \``cons`` [1,2,3]
    -- [4,1,2,3]
    -- @
    cons :: Element seq -> seq -> seq

    -- | Append an element onto a sequence.
    --
    -- @
    -- > [1,2,3] \``snoc`` 4
    -- [1,2,3,4]
    -- @
    snoc :: seq -> Element seq -> seq

-- | Create a sequence from a single element.
--
-- @
-- > 'singleton' 'a' :: 'String'
-- "a"
-- > 'singleton' 'a' :: 'Vector' 'Char'
-- 'Data.Vector.fromList' "a"
-- @
singleton :: IsSequence seq => Element seq -> seq
singleton = opoint
{-# INLINE singleton #-}

-- | Sequence Laws:
--
-- @
-- 'fromList' . 'otoList' = 'id'
-- 'fromList' (x <> y) = 'fromList' x <> 'fromList' y
-- 'otoList' ('fromList' x <> 'fromList' y) = x <> y
-- @
class (Monoid seq, MonoTraversable seq, SemiSequence seq, MonoPointed seq) => IsSequence seq where
    -- | Convert a list to a sequence.
    --
    -- @
    -- > 'fromList' ['a', 'b', 'c'] :: Text
    -- "abc"
    -- @
    fromList :: [Element seq] -> seq
    -- this definition creates the Monoid constraint
    -- However, all the instances define their own fromList
    fromList = mconcat . fmap singleton

    -- below functions change type fron the perspective of NonEmpty

    -- | 'break' applies a predicate to a sequence, and returns a tuple where
    -- the first element is the longest prefix (possibly empty) of elements that
    -- /do not satisfy/ the predicate. The second element of the tuple is the
    -- remainder of the sequence.
    --
    -- @'break' p@ is equivalent to @'span' ('not' . p)@
    --
    -- @
    -- > 'break' (> 3) ('fromList' [1,2,3,4,1,2,3,4] :: 'Vector' 'Int')
    -- (fromList [1,2,3],fromList [4,1,2,3,4])
    --
    -- > 'break' (< 'z') ('fromList' "abc" :: 'Text')
    -- ("","abc")
    --
    -- > 'break' (> 'z') ('fromList' "abc" :: 'Text')
    -- ("abc","")
    -- @
    break :: (Element seq -> Bool) -> seq -> (seq, seq)
    break f = (fromList *** fromList) . List.break f . otoList

    -- | 'span' applies a predicate to a sequence, and returns a tuple where
    -- the first element is the longest prefix (possibly empty) that
    -- /does satisfy/ the predicate. The second element of the tuple is the
    -- remainder of the sequence.
    --
    -- @'span' p xs@ is equivalent to @('takeWhile' p xs, 'dropWhile' p xs)@
    --
    -- @
    -- > 'span' (< 3) ('fromList' [1,2,3,4,1,2,3,4] :: 'Vector' 'Int')
    -- (fromList [1,2],fromList [3,4,1,2,3,4])
    --
    -- > 'span' (< 'z') ('fromList' "abc" :: 'Text')
    -- ("abc","")
    --
    -- > 'span' (< 0) [1,2,3]
    -- ([],[1,2,3])
    -- @
    span :: (Element seq -> Bool) -> seq -> (seq, seq)
    span f = (fromList *** fromList) . List.span f . otoList

    -- | 'dropWhile' returns the suffix remaining after 'takeWhile'.
    --
    -- @
    -- > 'dropWhile' (< 3) [1,2,3,4,5,1,2,3]
    -- [3,4,5,1,2,3]
    --
    -- > 'dropWhile' (< 'z') ('fromList' "abc" :: 'Text')
    -- ""
    -- @
    dropWhile :: (Element seq -> Bool) -> seq -> seq
    dropWhile f = fromList . List.dropWhile f . otoList

    -- | 'takeWhile' applies a predicate to a sequence, and returns the
    -- longest prefix (possibly empty) of the sequence of elements that
    -- /satisfy/ the predicate.
    --
    -- @
    -- > 'takeWhile' (< 3) [1,2,3,4,5,1,2,3]
    -- [1,2]
    --
    -- > 'takeWhile' (< 'z') ('fromList' "abc" :: 'Text')
    -- "abc"
    -- @
    takeWhile :: (Element seq -> Bool) -> seq -> seq
    takeWhile f = fromList . List.takeWhile f . otoList

    -- | @'splitAt' n se@ returns a tuple where the first element is the prefix of
    -- the sequence @se@ with length @n@, and the second element is the remainder of
    -- the sequence.
    --
    -- @
    -- > 'splitAt' 6 "Hello world!"
    -- ("Hello ","world!")
    --
    -- > 'splitAt' 3 ('fromList' [1,2,3,4,5] :: 'Vector' 'Int')
    -- (fromList [1,2,3],fromList [4,5])
    -- @
    splitAt :: Index seq -> seq -> (seq, seq)
    splitAt i = (fromList *** fromList) . List.genericSplitAt i . otoList

    -- | Equivalent to 'splitAt'.
    unsafeSplitAt :: Index seq -> seq -> (seq, seq)
    unsafeSplitAt i seq = (unsafeTake i seq, unsafeDrop i seq)

    -- | @'take' n@ returns the prefix of a sequence of length @n@, or the
    -- sequence itself if @n > 'olength' seq@.
    --
    -- @
    -- > 'take' 3 "abcdefg"
    -- "abc"
    -- > 'take' 4 ('fromList' [1,2,3,4,5,6] :: 'Vector' 'Int')
    -- fromList [1,2,3,4]
    -- @
    take :: Index seq -> seq -> seq
    take i = fst . splitAt i

    -- | Equivalent to 'take'.
    unsafeTake :: Index seq -> seq -> seq
    unsafeTake = take

    -- | @'drop' n@ returns the suffix of a sequence after the first @n@
    -- elements, or an empty sequence if @n > 'olength' seq@.
    --
    -- @
    -- > 'drop' 3 "abcdefg"
    -- "defg"
    -- > 'drop' 4 ('fromList' [1,2,3,4,5,6] :: 'Vector' 'Int')
    -- fromList [5,6]
    -- @
    drop :: Index seq -> seq -> seq
    drop i = snd . splitAt i

    -- | Equivalent to 'drop'
    unsafeDrop :: Index seq -> seq -> seq
    unsafeDrop = drop

    -- | 'partition' takes a predicate and a sequence and returns the pair of
    -- sequences of elements which do and do not satisfy the predicate.
    --
    -- @
    -- 'partition' p se = ('filter' p se, 'filter' ('not' . p) se)
    -- @
    partition :: (Element seq -> Bool) -> seq -> (seq, seq)
    partition f = (fromList *** fromList) . List.partition f . otoList

    -- | 'uncons' returns the tuple of the first element of a sequence and the rest
    -- of the sequence, or 'Nothing' if the sequence is empty.
    --
    -- @
    -- > 'uncons' ('fromList' [1,2,3,4] :: 'Vector' 'Int')
    -- 'Just' (1,fromList [2,3,4])
    --
    -- > 'uncons' ([] :: ['Int'])
    -- 'Nothing'
    -- @
    uncons :: seq -> Maybe (Element seq, seq)
    uncons = fmap (second fromList) . uncons . otoList

    -- | 'unsnoc' returns the tuple of the init of a sequence and the last element,
    -- or 'Nothing' if the sequence is empty.
    --
    -- @
    -- > 'uncons' ('fromList' [1,2,3,4] :: 'Vector' 'Int')
    -- 'Just' (fromList [1,2,3],4)
    --
    -- > 'uncons' ([] :: ['Int'])
    -- 'Nothing'
    -- @
    unsnoc :: seq -> Maybe (seq, Element seq)
    unsnoc = fmap (first fromList) . unsnoc . otoList

    -- | 'filter' given a predicate returns a sequence of all elements that satisfy
    -- the predicate.
    --
    -- @
    -- > 'filter' (< 5) [1 .. 10]
    -- [1,2,3,4]
    -- @
    filter :: (Element seq -> Bool) -> seq -> seq
    filter f = fromList . List.filter f . otoList

    -- | The monadic version of 'filter'.
    filterM :: Monad m => (Element seq -> m Bool) -> seq -> m seq
    filterM f = liftM fromList . filterM f . otoList

    -- replicates are not in SemiSequence to allow for zero

    -- | @'replicate' n x@ is a sequence of length @n@ with @x@ as the
    -- value of every element.
    --
    -- @
    -- > 'replicate' 10 'a' :: Text
    -- "aaaaaaaaaa"
    -- @
    replicate :: Index seq -> Element seq -> seq
    replicate i = fromList . List.genericReplicate i

    -- | The monadic version of 'replicateM'.
    replicateM :: Monad m => Index seq -> m (Element seq) -> m seq
    replicateM i = liftM fromList . Control.Monad.replicateM (fromIntegral i)

    -- below functions are not in SemiSequence because they return a List (instead of NonEmpty)

    -- | 'group' takes a sequence and returns a list of sequences such that the
    -- concatenation of the result is equal to the argument. Each subsequence in
    -- the result contains only equal elements, using the supplied equality test.
    --
    -- @
    -- > 'groupBy' (==) "Mississippi"
    -- ["M","i","ss","i","ss","i","pp","i"]
    -- @
    groupBy :: (Element seq -> Element seq -> Bool) -> seq -> [seq]
    groupBy f = fmap fromList . List.groupBy f . otoList

    -- | Similar to standard 'groupBy', but operates on the whole collection,
    -- not just the consecutive items.
    groupAllOn :: Eq b => (Element seq -> b) -> seq -> [seq]
    groupAllOn f = fmap fromList . groupAllOn f . otoList

    -- | 'subsequences' returns a list of all subsequences of the argument.
    --
    -- @
    -- > 'subsequences' "abc"
    -- ["","a","b","ab","c","ac","bc","abc"]
    -- @
    subsequences :: seq -> [seq]
    subsequences = List.map fromList . List.subsequences . otoList

    -- | 'permutations' returns a list of all permutations of the argument.
    --
    -- @
    -- > 'permutations' "abc"
    -- ["abc","bac","cba","bca","cab","acb"]
    -- @
    permutations :: seq -> [seq]
    permutations = List.map fromList . List.permutations . otoList

    -- | __Unsafe__
    --
    -- Get the tail of a sequence, throw an exception if the sequence is empty.
    --
    -- @
    -- > 'tailEx' [1,2,3]
    -- [2,3]
    -- @
    tailEx :: seq -> seq
    tailEx = snd . maybe (error "Data.Sequences.tailEx") id . uncons

    -- | __Unsafe__
    --
    -- Get the init of a sequence, throw an exception if the sequence is empty.
    --
    -- @
    -- > 'initEx' [1,2,3]
    -- [1,2]
    -- @
    initEx :: seq -> seq
    initEx = fst . maybe (error "Data.Sequences.initEx") id . unsnoc

    -- | Equivalent to 'tailEx'.
    unsafeTail :: seq -> seq
    unsafeTail = tailEx

    -- | Equivalent to 'initEx'.
    unsafeInit :: seq -> seq
    unsafeInit = initEx

    -- | Get the element of a sequence at a certain index, returns 'Nothing'
    -- if that index does not exist.
    --
    -- @
    -- > 'index' ('fromList' [1,2,3] :: 'Vector' 'Int') 1
    -- 'Just' 2
    -- > 'index' ('fromList' [1,2,3] :: 'Vector' 'Int') 4
    -- 'Nothing'
    -- @
    index :: seq -> Index seq -> Maybe (Element seq)
    index seq' idx = headMay (drop idx seq')

    -- | __Unsafe__
    --
    -- Get the element of a sequence at a certain index, throws an exception
    -- if the index does not exist.
    indexEx :: seq -> Index seq -> Element seq
    indexEx seq' idx = maybe (error "Data.Sequences.indexEx") id (index seq' idx)

    -- | Equivalent to 'indexEx'.
    unsafeIndex :: seq -> Index seq -> Element seq
    unsafeIndex = indexEx

    -- | 'intercalate' @seq seqs@ inserts @seq@ in between @seqs@ and
    -- concatenates the result.
    --
    -- Since 0.9.3
    intercalate :: seq -> [seq] -> seq
    intercalate = defaultIntercalate

    -- | 'splitWhen' splits a sequence into components delimited by separators,
    -- where the predicate returns True for a separator element. The resulting
    -- components do not contain the separators. Two adjacent separators result
    -- in an empty component in the output. The number of resulting components
    -- is greater by one than number of separators.
    --
    -- Since 0.9.3
    splitWhen :: (Element seq -> Bool) -> seq -> [seq]
    splitWhen = defaultSplitWhen

    {-# INLINE fromList #-}
    {-# INLINE break #-}
    {-# INLINE span #-}
    {-# INLINE dropWhile #-}
    {-# INLINE takeWhile #-}
    {-# INLINE splitAt #-}
    {-# INLINE unsafeSplitAt #-}
    {-# INLINE take #-}
    {-# INLINE unsafeTake #-}
    {-# INLINE drop #-}
    {-# INLINE unsafeDrop #-}
    {-# INLINE partition #-}
    {-# INLINE uncons #-}
    {-# INLINE unsnoc #-}
    {-# INLINE filter #-}
    {-# INLINE filterM #-}
    {-# INLINE replicate #-}
    {-# INLINE replicateM #-}
    {-# INLINE groupBy #-}
    {-# INLINE groupAllOn #-}
    {-# INLINE subsequences #-}
    {-# INLINE permutations #-}
    {-# INLINE tailEx #-}
    {-# INLINE initEx #-}
    {-# INLINE unsafeTail #-}
    {-# INLINE unsafeInit #-}
    {-# INLINE index #-}
    {-# INLINE indexEx #-}
    {-# INLINE unsafeIndex #-}
    {-# INLINE splitWhen #-}

-- | Use "Data.List"'s implementation of 'Data.List.find'.
defaultFind :: MonoFoldable seq => (Element seq -> Bool) -> seq -> Maybe (Element seq)
defaultFind f = List.find f . otoList
{-# INLINE defaultFind #-}

-- | Use "Data.List"'s implementation of 'Data.List.intersperse'.
defaultIntersperse :: IsSequence seq => Element seq -> seq -> seq
defaultIntersperse e = fromList . List.intersperse e . otoList
{-# INLINE defaultIntersperse #-}

-- | Use "Data.List"'s implementation of 'Data.List.reverse'.
defaultReverse :: IsSequence seq => seq -> seq
defaultReverse = fromList . List.reverse . otoList
{-# INLINE defaultReverse #-}

-- | Use "Data.List"'s implementation of 'Data.List.sortBy'.
defaultSortBy :: IsSequence seq => (Element seq -> Element seq -> Ordering) -> seq -> seq
defaultSortBy f = fromList . sortBy f . otoList
{-# INLINE defaultSortBy #-}

-- | Default 'intercalate'
defaultIntercalate :: (IsSequence seq) => seq -> [seq] -> seq
defaultIntercalate _ [] = mempty
defaultIntercalate s (seq:seqs) = mconcat (seq : List.map (s `mappend`) seqs)
{-# INLINE defaultIntercalate #-}

-- | Use 'splitWhen' from "Data.List.Split"
defaultSplitWhen :: IsSequence seq => (Element seq -> Bool) -> seq -> [seq]
defaultSplitWhen f = List.map fromList . List.splitWhen f . otoList
{-# INLINE defaultSplitWhen #-}

-- | Sort a vector using an supplied element ordering function.
vectorSortBy :: VG.Vector v e => (e -> e -> Ordering) -> v e -> v e
vectorSortBy f = VG.modify (VAM.sortBy f)
{-# INLINE vectorSortBy #-}

-- | Sort a vector.
vectorSort :: (VG.Vector v e, Ord e) => v e -> v e
vectorSort = VG.modify VAM.sort
{-# INLINE vectorSort #-}

-- | Use "Data.List"'s 'Data.List.:' to prepend an element to a sequence.
defaultCons :: IsSequence seq => Element seq -> seq -> seq
defaultCons e = fromList . (e:) . otoList
{-# INLINE defaultCons #-}

-- | Use "Data.List"'s 'Data.List.++' to append an element to a sequence.
defaultSnoc :: IsSequence seq => seq -> Element seq -> seq
defaultSnoc seq e = fromList (otoList seq List.++ [e])
{-# INLINE defaultSnoc #-}

-- | like Data.List.tail, but an input of 'mempty' returns 'mempty'
tailDef :: IsSequence seq => seq -> seq
tailDef xs = case uncons xs of
               Nothing -> mempty
               Just tuple -> snd tuple
{-# INLINE tailDef #-}

-- | like Data.List.init, but an input of 'mempty' returns 'mempty'
initDef :: IsSequence seq => seq -> seq
initDef xs = case unsnoc xs of
               Nothing -> mempty
               Just tuple -> fst tuple
{-# INLINE initDef #-}

instance SemiSequence [a] where
    type Index [a] = Int
    intersperse = List.intersperse
    reverse = List.reverse
    find = List.find
    sortBy f = V.toList . sortBy f . V.fromList
    cons = (:)
    snoc = defaultSnoc
    {-# INLINE intersperse #-}
    {-# INLINE reverse #-}
    {-# INLINE find #-}
    {-# INLINE sortBy #-}
    {-# INLINE cons #-}
    {-# INLINE snoc #-}

instance IsSequence [a] where
    fromList = id
    filter = List.filter
    filterM = Control.Monad.filterM
    break = List.break
    span = List.span
    dropWhile = List.dropWhile
    takeWhile = List.takeWhile
    splitAt = List.splitAt
    take = List.take
    drop = List.drop
    uncons [] = Nothing
    uncons (x:xs) = Just (x, xs)
    unsnoc [] = Nothing
    unsnoc (x0:xs0) =
        Just (loop id x0 xs0)
      where
        loop front x [] = (front [], x)
        loop front x (y:z) = loop (front . (x:)) y z
    partition = List.partition
    replicate = List.replicate
    replicateM = Control.Monad.replicateM
    groupBy = List.groupBy
    groupAllOn f (head : tail) =
        (head : matches) : groupAllOn f nonMatches
      where
        (matches, nonMatches) = partition ((== f head) . f) tail
    groupAllOn _ [] = []
    intercalate = List.intercalate
    splitWhen = List.splitWhen
    {-# INLINE fromList #-}
    {-# INLINE break #-}
    {-# INLINE span #-}
    {-# INLINE dropWhile #-}
    {-# INLINE takeWhile #-}
    {-# INLINE splitAt #-}
    {-# INLINE take #-}
    {-# INLINE drop #-}
    {-# INLINE partition #-}
    {-# INLINE uncons #-}
    {-# INLINE unsnoc #-}
    {-# INLINE filter #-}
    {-# INLINE filterM #-}
    {-# INLINE replicate #-}
    {-# INLINE replicateM #-}
    {-# INLINE groupBy #-}
    {-# INLINE groupAllOn #-}
    {-# INLINE intercalate #-}
    {-# INLINE splitWhen #-}

instance SemiSequence (NE.NonEmpty a) where
    type Index (NE.NonEmpty a) = Int

    intersperse  = NE.intersperse
    reverse      = NE.reverse
    find x       = find x . NE.toList
    cons         = NE.cons
    snoc xs x    = NE.fromList $ flip snoc x $ NE.toList xs
    sortBy f     = NE.fromList . sortBy f . NE.toList
    {-# INLINE intersperse #-}
    {-# INLINE reverse #-}
    {-# INLINE find #-}
    {-# INLINE sortBy #-}
    {-# INLINE cons #-}
    {-# INLINE snoc #-}

instance SemiSequence S.ByteString where
    type Index S.ByteString = Int
    intersperse = S.intersperse
    reverse = S.reverse
    find = S.find
    cons = S.cons
    snoc = S.snoc
    sortBy = defaultSortBy
    {-# INLINE intersperse #-}
    {-# INLINE reverse #-}
    {-# INLINE find #-}
    {-# INLINE sortBy #-}
    {-# INLINE cons #-}
    {-# INLINE snoc #-}

instance IsSequence S.ByteString where
    fromList = S.pack
    replicate = S.replicate
    filter = S.filter
    break = S.break
    span = S.span
    dropWhile = S.dropWhile
    takeWhile = S.takeWhile
    splitAt = S.splitAt
    take = S.take
    unsafeTake = SU.unsafeTake
    drop = S.drop
    unsafeDrop = SU.unsafeDrop
    partition = S.partition
    uncons = S.uncons
    unsnoc s
        | S.null s = Nothing
        | otherwise = Just (S.init s, S.last s)
    groupBy = S.groupBy
    tailEx = S.tail
    initEx = S.init
    unsafeTail = SU.unsafeTail
    splitWhen f s | S.null s = [S.empty]
                  | otherwise = S.splitWith f s
    intercalate = S.intercalate
    {-# INLINE fromList #-}
    {-# INLINE break #-}
    {-# INLINE span #-}
    {-# INLINE dropWhile #-}
    {-# INLINE takeWhile #-}
    {-# INLINE splitAt #-}
    {-# INLINE take #-}
    {-# INLINE unsafeTake #-}
    {-# INLINE drop #-}
    {-# INLINE unsafeDrop #-}
    {-# INLINE partition #-}
    {-# INLINE uncons #-}
    {-# INLINE unsnoc #-}
    {-# INLINE filter #-}
    {-# INLINE replicate #-}
    {-# INLINE groupBy #-}
    {-# INLINE tailEx #-}
    {-# INLINE initEx #-}
    {-# INLINE unsafeTail #-}
    {-# INLINE splitWhen #-}
    {-# INLINE intercalate #-}

    index bs i
        | i >= S.length bs = Nothing
        | otherwise = Just (S.index bs i)
    indexEx = S.index
    unsafeIndex = SU.unsafeIndex
    {-# INLINE index #-}
    {-# INLINE indexEx #-}
    {-# INLINE unsafeIndex #-}

instance SemiSequence T.Text where
    type Index T.Text = Int
    intersperse = T.intersperse
    reverse = T.reverse
    find = T.find
    cons = T.cons
    snoc = T.snoc
    sortBy = defaultSortBy
    {-# INLINE intersperse #-}
    {-# INLINE reverse #-}
    {-# INLINE find #-}
    {-# INLINE sortBy #-}
    {-# INLINE cons #-}
    {-# INLINE snoc #-}

instance IsSequence T.Text where
    fromList = T.pack
    replicate i c = T.replicate i (T.singleton c)
    filter = T.filter
    break = T.break
    span = T.span
    dropWhile = T.dropWhile
    takeWhile = T.takeWhile
    splitAt = T.splitAt
    take = T.take
    drop = T.drop
    partition = T.partition
    uncons = T.uncons
    unsnoc t
        | T.null t = Nothing
        | otherwise = Just (T.init t, T.last t)
    groupBy = T.groupBy
    tailEx = T.tail
    initEx = T.init
    splitWhen = T.split
    intercalate = T.intercalate
    {-# INLINE fromList #-}
    {-# INLINE break #-}
    {-# INLINE span #-}
    {-# INLINE dropWhile #-}
    {-# INLINE takeWhile #-}
    {-# INLINE splitAt #-}
    {-# INLINE take #-}
    {-# INLINE drop #-}
    {-# INLINE partition #-}
    {-# INLINE uncons #-}
    {-# INLINE unsnoc #-}
    {-# INLINE filter #-}
    {-# INLINE replicate #-}
    {-# INLINE groupBy #-}
    {-# INLINE tailEx #-}
    {-# INLINE initEx #-}
    {-# INLINE splitWhen #-}
    {-# INLINE intercalate #-}

    index t i
        | i >= T.length t = Nothing
        | otherwise = Just (T.index t i)
    indexEx = T.index
    unsafeIndex = T.index
    {-# INLINE index #-}
    {-# INLINE indexEx #-}
    {-# INLINE unsafeIndex #-}

instance SemiSequence L.ByteString where
    type Index L.ByteString = Int64
    intersperse = L.intersperse
    reverse = L.reverse
    find = L.find
    cons = L.cons
    snoc = L.snoc
    sortBy = defaultSortBy
    {-# INLINE intersperse #-}
    {-# INLINE reverse #-}
    {-# INLINE find #-}
    {-# INLINE sortBy #-}
    {-# INLINE cons #-}
    {-# INLINE snoc #-}

instance IsSequence L.ByteString where
    fromList = L.pack
    replicate = L.replicate
    filter = L.filter
    break = L.break
    span = L.span
    dropWhile = L.dropWhile
    takeWhile = L.takeWhile
    splitAt = L.splitAt
    take = L.take
    drop = L.drop
    partition = L.partition
    uncons = L.uncons
    unsnoc s
        | L.null s = Nothing
        | otherwise = Just (L.init s, L.last s)
    groupBy = L.groupBy
    tailEx = L.tail
    initEx = L.init
    splitWhen f s | L.null s = [L.empty]
                  | otherwise = L.splitWith f s
    intercalate = L.intercalate
    {-# INLINE fromList #-}
    {-# INLINE break #-}
    {-# INLINE span #-}
    {-# INLINE dropWhile #-}
    {-# INLINE takeWhile #-}
    {-# INLINE splitAt #-}
    {-# INLINE take #-}
    {-# INLINE drop #-}
    {-# INLINE partition #-}
    {-# INLINE uncons #-}
    {-# INLINE unsnoc #-}
    {-# INLINE filter #-}
    {-# INLINE replicate #-}
    {-# INLINE groupBy #-}
    {-# INLINE tailEx #-}
    {-# INLINE initEx #-}
    {-# INLINE splitWhen #-}
    {-# INLINE intercalate #-}

    indexEx = L.index
    unsafeIndex = L.index
    {-# INLINE indexEx #-}
    {-# INLINE unsafeIndex #-}

instance SemiSequence TL.Text where
    type Index TL.Text = Int64
    intersperse = TL.intersperse
    reverse = TL.reverse
    find = TL.find
    cons = TL.cons
    snoc = TL.snoc
    sortBy = defaultSortBy
    {-# INLINE intersperse #-}
    {-# INLINE reverse #-}
    {-# INLINE find #-}
    {-# INLINE sortBy #-}
    {-# INLINE cons #-}
    {-# INLINE snoc #-}

instance IsSequence TL.Text where
    fromList = TL.pack
    replicate i c = TL.replicate i (TL.singleton c)
    filter = TL.filter
    break = TL.break
    span = TL.span
    dropWhile = TL.dropWhile
    takeWhile = TL.takeWhile
    splitAt = TL.splitAt
    take = TL.take
    drop = TL.drop
    partition = TL.partition
    uncons = TL.uncons
    unsnoc t
        | TL.null t = Nothing
        | otherwise = Just (TL.init t, TL.last t)
    groupBy = TL.groupBy
    tailEx = TL.tail
    initEx = TL.init
    splitWhen = TL.split
    intercalate = TL.intercalate
    {-# INLINE fromList #-}
    {-# INLINE break #-}
    {-# INLINE span #-}
    {-# INLINE dropWhile #-}
    {-# INLINE takeWhile #-}
    {-# INLINE splitAt #-}
    {-# INLINE take #-}
    {-# INLINE drop #-}
    {-# INLINE partition #-}
    {-# INLINE uncons #-}
    {-# INLINE unsnoc #-}
    {-# INLINE filter #-}
    {-# INLINE replicate #-}
    {-# INLINE groupBy #-}
    {-# INLINE tailEx #-}
    {-# INLINE initEx #-}
    {-# INLINE splitWhen #-}
    {-# INLINE intercalate #-}

    indexEx = TL.index
    unsafeIndex = TL.index
    {-# INLINE indexEx #-}
    {-# INLINE unsafeIndex #-}

instance SemiSequence (Seq.Seq a) where
    type Index (Seq.Seq a) = Int
    cons = (Seq.<|)
    snoc = (Seq.|>)
    reverse = Seq.reverse
    sortBy = Seq.sortBy

    intersperse = defaultIntersperse
    find = defaultFind
    {-# INLINE intersperse #-}
    {-# INLINE reverse #-}
    {-# INLINE find #-}
    {-# INLINE sortBy #-}
    {-# INLINE cons #-}
    {-# INLINE snoc #-}

instance IsSequence (Seq.Seq a) where
    fromList = Seq.fromList
    replicate = Seq.replicate
    replicateM = Seq.replicateM
    filter = Seq.filter
    --filterM = Seq.filterM
    break = Seq.breakl
    span = Seq.spanl
    dropWhile = Seq.dropWhileL
    takeWhile = Seq.takeWhileL
    splitAt = Seq.splitAt
    take = Seq.take
    drop = Seq.drop
    partition = Seq.partition
    uncons s =
        case Seq.viewl s of
            Seq.EmptyL -> Nothing
            x Seq.:< xs -> Just (x, xs)
    unsnoc s =
        case Seq.viewr s of
            Seq.EmptyR -> Nothing
            xs Seq.:> x -> Just (xs, x)
    --groupBy = Seq.groupBy
    tailEx = Seq.drop 1
    initEx xs = Seq.take (Seq.length xs - 1) xs
    {-# INLINE fromList #-}
    {-# INLINE break #-}
    {-# INLINE span #-}
    {-# INLINE dropWhile #-}
    {-# INLINE takeWhile #-}
    {-# INLINE splitAt #-}
    {-# INLINE take #-}
    {-# INLINE drop #-}
    {-# INLINE partition #-}
    {-# INLINE uncons #-}
    {-# INLINE unsnoc #-}
    {-# INLINE filter #-}
    {-# INLINE replicate #-}
    {-# INLINE replicateM #-}
    {-# INLINE tailEx #-}
    {-# INLINE initEx #-}

    index seq' i
        | i >= Seq.length seq' = Nothing
        | otherwise = Just (Seq.index seq' i)
    indexEx = Seq.index
    unsafeIndex = Seq.index
    {-# INLINE index #-}
    {-# INLINE indexEx #-}
    {-# INLINE unsafeIndex #-}

instance SemiSequence (DList.DList a) where
    type Index (DList.DList a) = Int
    cons = DList.cons
    snoc = DList.snoc

    reverse = defaultReverse
    sortBy = defaultSortBy
    intersperse = defaultIntersperse
    find = defaultFind
    {-# INLINE intersperse #-}
    {-# INLINE reverse #-}
    {-# INLINE find #-}
    {-# INLINE sortBy #-}
    {-# INLINE cons #-}
    {-# INLINE snoc #-}

instance IsSequence (DList.DList a) where
    fromList = DList.fromList
    replicate = DList.replicate
    tailEx = DList.tail
    {-# INLINE fromList #-}
    {-# INLINE replicate #-}
    {-# INLINE tailEx #-}

instance SemiSequence (V.Vector a) where
    type Index (V.Vector a) = Int
    reverse = V.reverse
    find = V.find
    cons = V.cons
    snoc = V.snoc

    sortBy = vectorSortBy
    intersperse = defaultIntersperse
    {-# INLINE intersperse #-}
    {-# INLINE reverse #-}
    {-# INLINE find #-}
    {-# INLINE sortBy #-}
    {-# INLINE cons #-}
    {-# INLINE snoc #-}

instance IsSequence (V.Vector a) where
    fromList = V.fromList
    replicate = V.replicate
    replicateM = V.replicateM
    filter = V.filter
    filterM = V.filterM
    break = V.break
    span = V.span
    dropWhile = V.dropWhile
    takeWhile = V.takeWhile
    splitAt = V.splitAt
    take = V.take
    drop = V.drop
    unsafeTake = V.unsafeTake
    unsafeDrop = V.unsafeDrop
    partition = V.partition
    uncons v
        | V.null v = Nothing
        | otherwise = Just (V.head v, V.tail v)
    unsnoc v
        | V.null v = Nothing
        | otherwise = Just (V.init v, V.last v)
    --groupBy = V.groupBy
    tailEx = V.tail
    initEx = V.init
    unsafeTail = V.unsafeTail
    unsafeInit = V.unsafeInit
    {-# INLINE fromList #-}
    {-# INLINE break #-}
    {-# INLINE span #-}
    {-# INLINE dropWhile #-}
    {-# INLINE takeWhile #-}
    {-# INLINE splitAt #-}
    {-# INLINE take #-}
    {-# INLINE unsafeTake #-}
    {-# INLINE drop #-}
    {-# INLINE unsafeDrop #-}
    {-# INLINE partition #-}
    {-# INLINE uncons #-}
    {-# INLINE unsnoc #-}
    {-# INLINE filter #-}
    {-# INLINE filterM #-}
    {-# INLINE replicate #-}
    {-# INLINE replicateM #-}
    {-# INLINE tailEx #-}
    {-# INLINE initEx #-}
    {-# INLINE unsafeTail #-}
    {-# INLINE unsafeInit #-}

    index v i
        | i >= V.length v = Nothing
        | otherwise = Just (v V.! i)
    indexEx = (V.!)
    unsafeIndex = V.unsafeIndex
    {-# INLINE index #-}
    {-# INLINE indexEx #-}
    {-# INLINE unsafeIndex #-}

instance U.Unbox a => SemiSequence (U.Vector a) where
    type Index (U.Vector a) = Int

    intersperse = defaultIntersperse
    reverse = U.reverse
    find = U.find
    cons = U.cons
    snoc = U.snoc
    sortBy = vectorSortBy
    {-# INLINE intersperse #-}
    {-# INLINE reverse #-}
    {-# INLINE find #-}
    {-# INLINE sortBy #-}
    {-# INLINE cons #-}
    {-# INLINE snoc #-}

instance U.Unbox a => IsSequence (U.Vector a) where
    fromList = U.fromList
    replicate = U.replicate
    replicateM = U.replicateM
    filter = U.filter
    filterM = U.filterM
    break = U.break
    span = U.span
    dropWhile = U.dropWhile
    takeWhile = U.takeWhile
    splitAt = U.splitAt
    take = U.take
    drop = U.drop
    unsafeTake = U.unsafeTake
    unsafeDrop = U.unsafeDrop
    partition = U.partition
    uncons v
        | U.null v = Nothing
        | otherwise = Just (U.head v, U.tail v)
    unsnoc v
        | U.null v = Nothing
        | otherwise = Just (U.init v, U.last v)
    --groupBy = U.groupBy
    tailEx = U.tail
    initEx = U.init
    unsafeTail = U.unsafeTail
    unsafeInit = U.unsafeInit
    {-# INLINE fromList #-}
    {-# INLINE break #-}
    {-# INLINE span #-}
    {-# INLINE dropWhile #-}
    {-# INLINE takeWhile #-}
    {-# INLINE splitAt #-}
    {-# INLINE take #-}
    {-# INLINE unsafeTake #-}
    {-# INLINE drop #-}
    {-# INLINE unsafeDrop #-}
    {-# INLINE partition #-}
    {-# INLINE uncons #-}
    {-# INLINE unsnoc #-}
    {-# INLINE filter #-}
    {-# INLINE filterM #-}
    {-# INLINE replicate #-}
    {-# INLINE replicateM #-}
    {-# INLINE tailEx #-}
    {-# INLINE initEx #-}
    {-# INLINE unsafeTail #-}
    {-# INLINE unsafeInit #-}

    index v i
        | i >= U.length v = Nothing
        | otherwise = Just (v U.! i)
    indexEx = (U.!)
    unsafeIndex = U.unsafeIndex
    {-# INLINE index #-}
    {-# INLINE indexEx #-}
    {-# INLINE unsafeIndex #-}

instance VS.Storable a => SemiSequence (VS.Vector a) where
    type Index (VS.Vector a) = Int
    reverse = VS.reverse
    find = VS.find
    cons = VS.cons
    snoc = VS.snoc

    intersperse = defaultIntersperse
    sortBy = vectorSortBy
    {-# INLINE intersperse #-}
    {-# INLINE reverse #-}
    {-# INLINE find #-}
    {-# INLINE sortBy #-}
    {-# INLINE cons #-}
    {-# INLINE snoc #-}

instance VS.Storable a => IsSequence (VS.Vector a) where
    fromList = VS.fromList
    replicate = VS.replicate
    replicateM = VS.replicateM
    filter = VS.filter
    filterM = VS.filterM
    break = VS.break
    span = VS.span
    dropWhile = VS.dropWhile
    takeWhile = VS.takeWhile
    splitAt = VS.splitAt
    take = VS.take
    drop = VS.drop
    unsafeTake = VS.unsafeTake
    unsafeDrop = VS.unsafeDrop
    partition = VS.partition
    uncons v
        | VS.null v = Nothing
        | otherwise = Just (VS.head v, VS.tail v)
    unsnoc v
        | VS.null v = Nothing
        | otherwise = Just (VS.init v, VS.last v)
    --groupBy = U.groupBy
    tailEx = VS.tail
    initEx = VS.init
    unsafeTail = VS.unsafeTail
    unsafeInit = VS.unsafeInit
    {-# INLINE fromList #-}
    {-# INLINE break #-}
    {-# INLINE span #-}
    {-# INLINE dropWhile #-}
    {-# INLINE takeWhile #-}
    {-# INLINE splitAt #-}
    {-# INLINE take #-}
    {-# INLINE unsafeTake #-}
    {-# INLINE drop #-}
    {-# INLINE unsafeDrop #-}
    {-# INLINE partition #-}
    {-# INLINE uncons #-}
    {-# INLINE unsnoc #-}
    {-# INLINE filter #-}
    {-# INLINE filterM #-}
    {-# INLINE replicate #-}
    {-# INLINE replicateM #-}
    {-# INLINE tailEx #-}
    {-# INLINE initEx #-}
    {-# INLINE unsafeTail #-}
    {-# INLINE unsafeInit #-}

    index v i
        | i >= VS.length v = Nothing
        | otherwise = Just (v VS.! i)
    indexEx = (VS.!)
    unsafeIndex = VS.unsafeIndex
    {-# INLINE index #-}
    {-# INLINE indexEx #-}
    {-# INLINE unsafeIndex #-}

-- | A typeclass for sequences whose elements have the 'Eq' typeclass
class (MonoFoldableEq seq, IsSequence seq, Eq (Element seq)) => EqSequence seq where

    -- | @'splitElem'@ splits a sequence into components delimited by separator
    -- element. It's equivalent to 'splitWhen' with equality predicate:
    --
    -- > splitElem sep === splitWhen (== sep)
    --
    -- Since 0.9.3
    splitElem :: Element seq -> seq -> [seq]
    splitElem x = splitWhen (== x)

    -- | @'splitSeq'@ splits a sequence into components delimited by
    -- separator subsequence. 'splitSeq' is the right inverse of 'intercalate':
    --
    -- > intercalate x . splitSeq x === id
    --
    -- 'splitElem' can be considered a special case of 'splitSeq'
    --
    -- > splitSeq (singleton sep) === splitElem sep
    --
    -- @'splitSeq' mempty@ is another special case: it splits just before each
    -- element, and in line with 'splitWhen' rules, it has at least one output
    -- component:
    --
    -- @
    -- > 'splitSeq' "" ""
    -- [""]
    -- > 'splitSeq' "" "a"
    -- ["", "a"]
    -- > 'splitSeq' "" "ab"
    -- ["", "a", "b"]
    -- @
    --
    -- Since 0.9.3
    splitSeq :: seq -> seq -> [seq]
    splitSeq = defaultSplitOn

    -- | 'stripPrefix' drops the given prefix from a sequence.
    -- It returns 'Nothing' if the sequence did not start with the prefix
    -- given, or 'Just' the sequence after the prefix, if it does.
    --
    -- @
    -- > 'stripPrefix' "foo" "foobar"
    -- 'Just' "foo"
    -- > 'stripPrefix' "abc" "foobar"
    -- 'Nothing'
    -- @
    stripPrefix :: seq -> seq -> Maybe seq
    stripPrefix x y = fmap fromList (otoList x `stripPrefix` otoList y)

    -- | 'stripSuffix' drops the given suffix from a sequence.
    -- It returns 'Nothing' if the sequence did not end with the suffix
    -- given, or 'Just' the sequence before the suffix, if it does.
    --
    -- @
    -- > 'stripSuffix' "bar" "foobar"
    -- 'Just' "foo"
    -- > 'stripSuffix' "abc" "foobar"
    -- 'Nothing'
    -- @
    stripSuffix :: seq -> seq -> Maybe seq
    stripSuffix x y = fmap fromList (otoList x `stripSuffix` otoList y)

    -- | 'isPrefixOf' takes two sequences and returns 'True' if the first
    -- sequence is a prefix of the second.
    isPrefixOf :: seq -> seq -> Bool
    isPrefixOf x y = otoList x `isPrefixOf` otoList y

    -- | 'isSuffixOf' takes two sequences and returns 'True' if the first
    -- sequence is a suffix of the second.
    isSuffixOf :: seq -> seq -> Bool
    isSuffixOf x y = otoList x `isSuffixOf` otoList y

    -- | 'isInfixOf' takes two sequences and returns 'true' if the first
    -- sequence is contained, wholly and intact, anywhere within the second.
    isInfixOf :: seq -> seq -> Bool
    isInfixOf x y = otoList x `isInfixOf` otoList y

    -- | Equivalent to @'groupBy' (==)@
    group :: seq -> [seq]
    group = groupBy (==)

    -- | Similar to standard 'group', but operates on the whole collection,
    -- not just the consecutive items.
    --
    -- Equivalent to @'groupAllOn' id@
    groupAll :: seq -> [seq]
    groupAll = groupAllOn id

    -- |
    --
    -- @since 0.10.2
    delete :: Element seq -> seq -> seq
    delete = deleteBy (==)

    -- |
    --
    -- @since 0.10.2
    deleteBy :: (Element seq -> Element seq -> Bool) -> Element seq -> seq -> seq
    deleteBy eq x = fromList . List.deleteBy eq x . otoList
    {-# INLINE splitElem #-}
    {-# INLINE splitSeq #-}
    {-# INLINE isPrefixOf #-}
    {-# INLINE isSuffixOf #-}
    {-# INLINE isInfixOf #-}
    {-# INLINE stripPrefix #-}
    {-# INLINE stripSuffix #-}
    {-# INLINE group #-}
    {-# INLINE groupAll #-}
    {-# INLINE delete #-}
    {-# INLINE deleteBy #-}

{-# DEPRECATED elem "use oelem" #-}
elem :: EqSequence seq => Element seq -> seq -> Bool
elem = oelem

{-# DEPRECATED notElem "use onotElem" #-}
notElem :: EqSequence seq => Element seq -> seq -> Bool
notElem = onotElem

-- | Use 'splitOn' from "Data.List.Split"
defaultSplitOn :: EqSequence s => s -> s -> [s]
defaultSplitOn sep = List.map fromList . List.splitOn (otoList sep) . otoList

instance Eq a => EqSequence [a] where
    splitSeq = List.splitOn
    stripPrefix = List.stripPrefix
    stripSuffix x y = fmap reverse (List.stripPrefix (reverse x) (reverse y))
    group = List.group
    isPrefixOf = List.isPrefixOf
    isSuffixOf x y = List.isPrefixOf (List.reverse x) (List.reverse y)
    isInfixOf = List.isInfixOf
    delete = List.delete
    deleteBy = List.deleteBy
    {-# INLINE splitSeq #-}
    {-# INLINE stripPrefix #-}
    {-# INLINE stripSuffix #-}
    {-# INLINE group #-}
    {-# INLINE isPrefixOf #-}
    {-# INLINE isSuffixOf #-}
    {-# INLINE isInfixOf #-}
    {-# INLINE delete #-}
    {-# INLINE deleteBy #-}

instance EqSequence S.ByteString where
    splitElem sep s | S.null s = [S.empty]
                    | otherwise = S.split sep s
    stripPrefix x y
        | x `S.isPrefixOf` y = Just (S.drop (S.length x) y)
        | otherwise = Nothing
    stripSuffix x y
        | x `S.isSuffixOf` y = Just (S.take (S.length y - S.length x) y)
        | otherwise = Nothing
    group = S.group
    isPrefixOf = S.isPrefixOf
    isSuffixOf = S.isSuffixOf
    isInfixOf = S.isInfixOf
    {-# INLINE splitElem #-}
    {-# INLINE stripPrefix #-}
    {-# INLINE stripSuffix #-}
    {-# INLINE group #-}
    {-# INLINE isPrefixOf #-}
    {-# INLINE isSuffixOf #-}
    {-# INLINE isInfixOf #-}

instance EqSequence L.ByteString where
    splitElem sep s | L.null s = [L.empty]
                    | otherwise = L.split sep s
    stripPrefix x y
        | x `L.isPrefixOf` y = Just (L.drop (L.length x) y)
        | otherwise = Nothing
    stripSuffix x y
        | x `L.isSuffixOf` y = Just (L.take (L.length y - L.length x) y)
        | otherwise = Nothing
    group = L.group
    isPrefixOf = L.isPrefixOf
    isSuffixOf = L.isSuffixOf
    isInfixOf x y = L.unpack x `List.isInfixOf` L.unpack y
    {-# INLINE splitElem #-}
    {-# INLINE stripPrefix #-}
    {-# INLINE stripSuffix #-}
    {-# INLINE group #-}
    {-# INLINE isPrefixOf #-}
    {-# INLINE isSuffixOf #-}
    {-# INLINE isInfixOf #-}

instance EqSequence T.Text where
    splitSeq sep | T.null sep = (:) T.empty . List.map singleton . T.unpack
                 | otherwise = T.splitOn sep
    stripPrefix = T.stripPrefix
    stripSuffix = T.stripSuffix
    group = T.group
    isPrefixOf = T.isPrefixOf
    isSuffixOf = T.isSuffixOf
    isInfixOf = T.isInfixOf
    {-# INLINE splitSeq #-}
    {-# INLINE stripPrefix #-}
    {-# INLINE stripSuffix #-}
    {-# INLINE group #-}
    {-# INLINE isPrefixOf #-}
    {-# INLINE isSuffixOf #-}
    {-# INLINE isInfixOf #-}

instance EqSequence TL.Text where
    splitSeq sep | TL.null sep = (:) TL.empty . List.map singleton . TL.unpack
                 | otherwise = TL.splitOn sep
    stripPrefix = TL.stripPrefix
    stripSuffix = TL.stripSuffix
    group = TL.group
    isPrefixOf = TL.isPrefixOf
    isSuffixOf = TL.isSuffixOf
    isInfixOf = TL.isInfixOf
    {-# INLINE splitSeq #-}
    {-# INLINE stripPrefix #-}
    {-# INLINE stripSuffix #-}
    {-# INLINE group #-}
    {-# INLINE isPrefixOf #-}
    {-# INLINE isSuffixOf #-}
    {-# INLINE isInfixOf #-}

instance Eq a => EqSequence (Seq.Seq a)
instance Eq a => EqSequence (V.Vector a)
instance (Eq a, U.Unbox a) => EqSequence (U.Vector a)
instance (Eq a, VS.Storable a) => EqSequence (VS.Vector a)

-- | A typeclass for sequences whose elements have the 'Ord' typeclass
class (EqSequence seq, MonoFoldableOrd seq) => OrdSequence seq where
    -- | Sort a ordered sequence.
    --
    -- @
    -- > 'sort' [4,3,1,2]
    -- [1,2,3,4]
    -- @
    sort :: seq -> seq
    sort = fromList . sort . otoList
    {-# INLINE sort #-}

instance Ord a => OrdSequence [a] where
    sort = V.toList . sort . V.fromList
    {-# INLINE sort #-}

instance OrdSequence S.ByteString where
    sort = S.sort
    {-# INLINE sort #-}

instance OrdSequence L.ByteString
instance OrdSequence T.Text
instance OrdSequence TL.Text
instance Ord a => OrdSequence (Seq.Seq a)

instance Ord a => OrdSequence (V.Vector a) where
    sort = vectorSort
    {-# INLINE sort #-}

instance (Ord a, U.Unbox a) => OrdSequence (U.Vector a) where
    sort = vectorSort
    {-# INLINE sort #-}

instance (Ord a, VS.Storable a) => OrdSequence (VS.Vector a) where
    sort = vectorSort
    {-# INLINE sort #-}

-- | A typeclass for sequences whose elements are 'Char's.
class (IsSequence t, IsString t, Element t ~ Char) => Textual t where
    -- | Break up a textual sequence into a list of words, which were delimited
    -- by white space.
    --
    -- @
    -- > 'words' "abc  def ghi"
    -- ["abc","def","ghi"]
    -- @
    words :: t -> [t]

    -- | Join a list of textual sequences using seperating spaces.
    --
    -- @
    -- > 'unwords' ["abc","def","ghi"]
    -- "abc def ghi"
    -- @
    unwords :: [t] -> t

    -- | Break up a textual sequence at newline characters.
    --
    --
    -- @
    -- > 'lines' "hello\\nworld"
    -- ["hello","world"]
    -- @
    lines :: t -> [t]

    -- | Join a list of textual sequences using newlines.
    --
    -- @
    -- > 'unlines' ["abc","def","ghi"]
    -- "abc\\ndef\\nghi"
    -- @
    unlines :: [t] -> t

    -- | Convert a textual sequence to lower-case.
    --
    -- @
    -- > 'toLower' "HELLO WORLD"
    -- "hello world"
    -- @
    toLower :: t -> t

    -- | Convert a textual sequence to upper-case.
    --
    -- @
    -- > 'toUpper' "hello world"
    -- "HELLO WORLD"
    -- @
    toUpper :: t -> t

    -- | Convert a textual sequence to folded-case.
    --
    -- Slightly different from 'toLower', see @"Data.Text".'Data.Text.toCaseFold'@
    toCaseFold :: t -> t

    -- | Split a textual sequence into two parts, split at the first space.
    --
    -- @
    -- > 'breakWord' "hello world"
    -- ("hello","world")
    -- @
    breakWord :: t -> (t, t)
    breakWord = fmap (dropWhile isSpace) . break isSpace
    {-# INLINE breakWord #-}

    -- | Split a textual sequence into two parts, split at the newline.
    --
    -- @
    -- > 'breakLine' "abc\\ndef"
    -- ("abc","def")
    -- @
    breakLine :: t -> (t, t)
    breakLine =
        (killCR *** drop 1) . break (== '\n')
      where
        killCR t =
            case unsnoc t of
                Just (t', '\r') -> t'
                _ -> t

instance (c ~ Char) => Textual [c] where
    words = List.words
    unwords = List.unwords
    lines = List.lines
    unlines = List.unlines
    toLower = TL.unpack . TL.toLower . TL.pack
    toUpper = TL.unpack . TL.toUpper . TL.pack
    toCaseFold = TL.unpack . TL.toCaseFold . TL.pack
    {-# INLINE words #-}
    {-# INLINE unwords #-}
    {-# INLINE lines #-}
    {-# INLINE unlines #-}
    {-# INLINE toLower #-}
    {-# INLINE toUpper #-}
    {-# INLINE toCaseFold #-}

instance Textual T.Text where
    words = T.words
    unwords = T.unwords
    lines = T.lines
    unlines = T.unlines
    toLower = T.toLower
    toUpper = T.toUpper
    toCaseFold = T.toCaseFold
    {-# INLINE words #-}
    {-# INLINE unwords #-}
    {-# INLINE lines #-}
    {-# INLINE unlines #-}
    {-# INLINE toLower #-}
    {-# INLINE toUpper #-}
    {-# INLINE toCaseFold #-}

instance Textual TL.Text where
    words = TL.words
    unwords = TL.unwords
    lines = TL.lines
    unlines = TL.unlines
    toLower = TL.toLower
    toUpper = TL.toUpper
    toCaseFold = TL.toCaseFold
    {-# INLINE words #-}
    {-# INLINE unwords #-}
    {-# INLINE lines #-}
    {-# INLINE unlines #-}
    {-# INLINE toLower #-}
    {-# INLINE toUpper #-}
    {-# INLINE toCaseFold #-}

-- | Takes all of the `Just` values from a sequence of @Maybe t@s and
-- concatenates them into an unboxed sequence of @t@s.
--
-- Since 0.6.2
catMaybes :: (IsSequence (f (Maybe t)), Functor f,
              Element (f (Maybe t)) ~ Maybe t)
          => f (Maybe t) -> f t
catMaybes = fmap fromJust . filter isJust

-- | Same as @sortBy . comparing@.
--
-- Since 0.7.0
sortOn :: (Ord o, SemiSequence seq) => (Element seq -> o) -> seq -> seq
sortOn = sortBy . comparing
{-# INLINE sortOn #-}
