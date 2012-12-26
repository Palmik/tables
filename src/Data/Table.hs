{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LiberalTypeSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Table
-- Copyright   :  (C) 2012 Edward Kmett,
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable
--
----------------------------------------------------------------------------
module Data.Table
  (
  -- * Tables
    Table(..)
  -- ** Table Construction
  , empty
  , singleton
  , table
  , fromList
  -- ** Reading and Writing
  , null
  , insert
  , With(..)
  , Group(..)
  , delete
  , deleteWith
  , rows
  , rows'
  -- * Esoterica
  , autoIncrement
  -- * Implementation Details
  , Tabular(..)
  , KeyType(..)
  , Primary
  , Candidate
  , Supplemental
  , Index(..)
  ) where

import Control.Applicative hiding (empty)
import Control.Lens
import Data.Data
import Data.Foldable as Foldable
import Data.Function (on)
import Data.Functor.Identity
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Monoid
import Data.Traversable
import qualified Prelude
import Prelude hiding (null)

{-# ANN module "HLint: ignore Reduce duplication" #-}
{-# ANN module "HLint: ignore Eta reduce" #-}

class Ord (PKT t) => Tabular (t :: *) where
  -- | The type of the primary key
  type PKT t :: *
  -- | The type used internally for tables
  data Tab t :: *
  -- | The type used internally for columns
  data Key (k :: * -> *) t ::  * -> *

  -- | evaluate an internal column
  val     :: Key k t a -> t -> a

  -- | Every relation has one primary key
  primary :: Key Primary t (PKT t)

  -- | ... and so if you find one, it had better be that one!
  primarily  :: Key Primary t a -> ((a ~ PKT t) => r) -> r

  -- | Construct a table given a function from key to index.
  tabulate   :: (forall k a. (IsKeyType k, Ord a) => Key k t a -> Index k t a) -> Tab t

  -- | Lookup an index
  ixMeta     :: Tab t -> Key k t a -> Index k t a

  -- | Loop over each index
  forMeta    :: Applicative h => Tab t -> (forall k a . Key k t a -> Index k t a -> h (Index k t a)) -> h (Tab t)

  -- | Find the primary key in a table
  prim       :: Lens' (Tab t) (Index Primary t (PKT t))

  -- | Adjust a record using meta-information about the table allowing for auto-increments, etc.
  autoKey    :: t -> Maybe (Tab t -> (t, Tab t))
  autoKey _ = Nothing

-- | This lets you define 'autoKey' to increment to 1 greater than the existing maximum key in a table.
autoIncrement :: (Tabular t, Num a, PKT t ~ a) => Loupe' t a -> t -> Maybe (Tab t -> (t, Tab t))
autoIncrement pk t
  | t ^# pk == 0 = Just $ \ tb -> (t & pk #~ 1 + fromMaybe 0 (tb^?primaryMap.indicesOf traverseMax), tb)
  | otherwise    = Nothing

data Index k t a where
  PrimaryIndex      :: Map a t            -> Index Primary      t a
  CandidateIndex    :: Ord a => Map a t   -> Index Candidate    t a
  SupplementalIndex :: Ord a => Map a [t] -> Index Supplemental t a

primaryMap :: Tabular t => Lens' (Tab t) (Map (PKT t) t)
primaryMap = prim . \ f (PrimaryIndex m) -> PrimaryIndex <$> f m
{-# INLINE primaryMap #-}

-- * Overloaded keys

------------------------------------------------------------------------------
-- Table
------------------------------------------------------------------------------

data Table t where
  EmptyTable ::                       Table t
  Table      :: Tabular t => Tab t -> Table t
  deriving Typeable

instance (Tabular t, Data t) => Data (Table t) where
  gfoldl f z im = z fromList `f` toList im
  toConstr _ = fromListConstr
  gunfold k z c = case constrIndex c of
    1 -> k (z fromList)
    _ -> error "gunfold"
  dataTypeOf _ = tableDataType
  dataCast1 f = gcast1 f

fromListConstr :: Constr
fromListConstr = mkConstr tableDataType "fromList" [] Prefix

tableDataType :: DataType
tableDataType = mkDataType "Data.Table.Table" [fromListConstr]

instance Monoid (Table t) where
  mempty = EmptyTable
  {-# INLINE mempty #-}

  EmptyTable `mappend` r          = r
  r          `mappend` EmptyTable = r
  r@Table{}  `mappend` s          = Foldable.foldl' (flip insert) r s
  {-# INLINE mappend #-}

instance Eq t => Eq (Table t) where
  (==) = (==) `on` toList
  {-# INLINE (==) #-}

instance Ord t => Ord (Table t) where
  compare = compare `on` toList
  {-# INLINE compare #-}

instance Show t => Show (Table t) where
  showsPrec d t = showParen (d > 10) $ showString "fromList " . showsPrec 11 (toList t)

instance (Tabular t, Read t) => Read (Table t) where
  readsPrec d = readParen (d > 10) $ \r -> do
    ("fromList",s) <- lex r
    (m, t) <- readsPrec 11 s
    return (fromList m, t)

instance Foldable Table where
  foldMap _ EmptyTable = mempty
  foldMap f (Table m)  = foldMapOf (primaryMap.folded) f m
  {-# INLINE foldMap #-}

deleteCollisions :: Table t -> [t] -> Table t
deleteCollisions EmptyTable _ = EmptyTable
deleteCollisions (Table tab) ts = Table $ runIdentity $ forMeta tab $ \k i -> Identity $ case i of
  PrimaryIndex idx      -> PrimaryIndex $ primarily k $ foldl' (flip (Map.delete . val primary)) idx ts
  CandidateIndex idx    -> CandidateIndex $ foldl' (flip (Map.delete . val k)) idx ts
  SupplementalIndex idx -> SupplementalIndex $ Map.foldlWithKey' ?? idx ?? Map.fromListWith (++) [ (val k t, [t]) | t <- ts ] $ \m ky ys ->
    m & at ky . anon [] Prelude.null %~ let pys = val primary <$> ys in filter (\e -> val primary e `Prelude.notElem` pys)
{-# INLINE deleteCollisions #-}

emptyTab :: Tabular t => Tab t
emptyTab = tabulate $ \k -> case keyType k of
  Primary      -> primarily k (PrimaryIndex Map.empty)
  Candidate    -> CandidateIndex Map.empty
  Supplemental -> SupplementalIndex Map.empty
{-# INLINE emptyTab #-}

-- * Public API

-- | Construct an empty relation
empty :: Table t
empty = EmptyTable
{-# INLINE empty #-}

-- | Check to see if the relation is empty
null :: Table t -> Bool
null EmptyTable = True
null (Table m)  = Map.null (m^.primaryMap)
{-# INLINE null #-}

-- | Construct a relation with a single row
singleton :: Tabular t => t -> Table t
singleton row = Table $ tabulate $ \ k -> case keyType k of
  Primary      -> primarily k $ PrimaryIndex $ Map.singleton (val k row) row
  Candidate    -> CandidateIndex             $ Map.singleton (val k row) row
  Supplemental -> SupplementalIndex          $ Map.singleton (val k row) [row]
{-# INLINE singleton #-}

-- | Return the set of rows that would be delete by deleting or inserting this row
collisions :: t -> Table t -> [t]
collisions _ EmptyTable = []
collisions t (Table m)  = getConst $ forMeta m $ \k i -> Const $ case i of
  PrimaryIndex idx   -> primarily k $ idx^..ix (val k t)
  CandidateIndex idx ->               idx^..ix (val k t)
  _                  -> []
{-# INLINE collisions #-}

-- | Delete this row from the database
delete :: t -> Table t -> Table t
delete t m = deleteCollisions m (collisions t m)
{-# INLINE delete #-}

-- | Insert a row into a relation, removing collisions.
insert :: Tabular t => t -> Table t -> Table t
insert t0 r0 = case autoKey t0 of
  Just p -> case r0 of
    EmptyTable -> case p emptyTab of
      (t1,m1) -> go t1 (Table m1)
    Table m    -> case p m of
      (t1,m1) -> go t1 (Table m1)
  Nothing -> go t0 r0
  where
  go t r = case delete t r of
    EmptyTable -> singleton t
    Table m -> Table $ runIdentity $ forMeta m $ \k i -> Identity $ case i of
      PrimaryIndex idx      -> primarily k $ PrimaryIndex $ idx & at (val k t) ?~ t
      CandidateIndex idx    -> CandidateIndex             $ idx & at (val k t) ?~ t
      SupplementalIndex idx -> SupplementalIndex          $ idx & at (val k t) . anon [] Prelude.null %~ (t:)
  {-# INLINE go #-}
{-# INLINE insert #-}

-- | Convert a list to and from a 'Table'.
--
-- The real isomorphism laws hold if the original list makes no use of the auto-increment
-- functionality of the table, has no duplicates and is sorted according to the primary key.
--
-- However,
--
-- @'from' 'table' '.' 'table' ≡ 'id'@
--
-- always holds.
table :: Tabular t => Iso' [t] (Table t)
table = iso fromList toList
{-# INLINE table #-}

-- | Select a smaller, updateable subset of the rows of a table using an index or an arbitrary function.
class With q t | q -> t where
  with :: Ord a => q a -> (forall x. Ord x => x -> x -> Bool) -> a -> Lens' (Table t) (Table t)

instance With ((->) t) t where
  with _  _   _ f EmptyTable  = f EmptyTable
  with ky cmp a f r@(Table m)
    | lt && eq && gt = f r
    | lt || eq || gt = go $ m^..primaryMap.folded.filtered (\row -> cmp (ky row) a)
    | otherwise      = f EmptyTable <&> mappend r
    where
      lt = cmp LT EQ
      eq = cmp EQ EQ
      gt = cmp GT EQ
      go xs = f (xs^.table) <&> mappend (deleteCollisions r xs)

instance (IsKeyType k, Tabular t) => With (Key k t) t where
  with _   _   _ f EmptyTable  = f EmptyTable
  with ky cmp a f r@(Table m)
    | lt && eq && gt = f r -- all rows
    | not lt && eq && not gt = case ixMeta m ky of
      PrimaryIndex idx      -> go $ primarily ky (idx^..ix a)
      CandidateIndex idx    -> go $ idx^..ix a
      SupplementalIndex idx -> go $ idx^..ix a.folded
    | lt || eq || gt = case ixMeta m ky of
      PrimaryIndex idx -> primarily ky $ case Map.splitLookup a idx of
        (l,e,g) -> go $ (if lt then Foldable.toList l else [])
                     ++ (if eq then Foldable.toList e else [])
                     ++ (if gt then Foldable.toList g else [])
      CandidateIndex idx -> case Map.splitLookup a idx of
        (l,e,g) -> go $ (if lt then Foldable.toList l else [])
                     ++ (if eq then Foldable.toList e else [])
                     ++ (if gt then Foldable.toList g else [])
      SupplementalIndex idx -> case Map.splitLookup a idx of
        (l,e,g) -> go $ (if lt then Foldable.concat l else [])
                     ++ (if eq then Foldable.concat e else [])
                     ++ (if gt then Foldable.concat g else [])
    | otherwise      = f EmptyTable <&> mappend r -- no match
    where
        lt = cmp LT EQ
        eq = cmp EQ EQ
        gt = cmp GT EQ
        go xs = f (xs^.table) <&> mappend (deleteCollisions r xs)
  {-# INLINE with #-}

-- | Delete selected rows from a table
--
-- @'deleteWith' p cmp a t ≡ 'set' ('with' p cmp a) 'empty' t@
deleteWith :: (With q t, Ord a) => q a -> (forall x. Ord x => x -> x -> Bool) -> a -> Table t -> Table t
deleteWith p cmp a t = set (with p cmp a) empty t
{-# INLINE deleteWith #-}

class Group q t | q -> t where
  group :: (Indexable a p, Applicative f, Ord a) => q a -> IndexedLensLike' p f (Table t) (Table t)

-- | Group by an arbitrary function
instance Group ((->) t) t where
  group _ _ EmptyTable = pure EmptyTable
  group ky f (Table m) = traverse (\(k,vs) -> indexed f k (fromList vs)) (Map.toList idx) <&> mconcat where 
    idx = Map.fromListWith (++) (m^..primaryMap.folded.to(\v -> (ky v, [v])))
  {-# INLINE group #-}

-- | Group by an index
instance Group (Key k t) t where
  group _ _ EmptyTable = pure EmptyTable
  group ky f (Table m) = case ixMeta m ky of
    PrimaryIndex idx      -> primarily ky $ for (toList idx) (\v -> indexed f (val primary v) (singleton v)) <&> mconcat
    CandidateIndex idx    -> traverse (\(k,v) -> indexed f k (singleton v)) (Map.toList idx) <&> mconcat
    SupplementalIndex idx -> traverse (\(k,vs) -> indexed f k (fromList vs)) (Map.toList idx) <&> mconcat
  {-# INLINE group #-}

-- * Traverse all of the rows in a table without changing any types
rows' :: Traversal' (Table t) t
rows' _ EmptyTable = pure EmptyTable
rows' f r@Table{} = Prelude.foldr insert empty <$> traverse f (toList r)
{-# INLINE rows' #-}

-- * Traverse all of the rows in a table, potentially changing table types completely.
rows :: Tabular t => Traversal (Table s) (Table t) s t
rows f r = Prelude.foldr insert empty <$> traverse f (toList r)
{-# INLINE rows #-}

-- * Build up a table from a list
fromList :: Tabular t => [t] -> Table t
fromList = foldl' (flip insert) empty
{-# INLINE fromList #-}

-- * Lifting terms to types

data KeyType t a where
  Primary      :: KeyType Primary a
  Candidate    :: KeyType Candidate a
  Supplemental :: KeyType Supplemental a

data Primary (a :: *)
data Candidate (a :: *)
data Supplemental (a :: *)

class IsKeyType k where
  keyType :: Key k t a -> KeyType k a

instance IsKeyType Primary where
  keyType _ = Primary
  {-# INLINE keyType #-}

instance IsKeyType Candidate where
  keyType _ = Candidate
  {-# INLINE keyType #-}

instance IsKeyType Supplemental where
  keyType _ = Supplemental
  {-# INLINE keyType #-}
