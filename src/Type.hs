{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
module Type where

import Control.Lens
import Control.Monad
import Data.Foldable
import Data.Map (Map)
import Data.Unique
import Numeric.Natural

import Alpha
import Datatype
import ShortShow

newtype MetaPtr = MetaPtr Unique deriving (Eq, Ord)

newMetaPtr :: IO MetaPtr
newMetaPtr = MetaPtr <$> newUnique

instance Show MetaPtr where
  show (MetaPtr i) = "(MetaPtr " ++ show (hashUnique i) ++ ")"

data TypeConstructor
  = TSyntax
  | TSignal
  | TString
  | TFun
  | TMacro
  | TType
  | TDatatype Datatype
  | TSchemaVar Natural
  | TMetaVar MetaPtr
  deriving (Eq, Show)
makePrisms ''TypeConstructor

data TyF t = TyF
  { outermostCtor :: TypeConstructor
  , typeArgs      :: [t]
  }
  deriving (Eq, Foldable, Functor, Show, Traversable)
makeLenses ''TyF

data VarKind t = NoLink | Link (TyF t)
  deriving (Functor, Show)
makePrisms ''VarKind

newtype BindingLevel = BindingLevel Natural
  deriving (Eq, Ord, Show)
makePrisms ''BindingLevel

data TVar t = TVar
  { _varKind :: !(VarKind t)
  , _varLevel :: !BindingLevel
  }
  deriving (Functor, Show)
makeLenses ''TVar

newtype TypeStore t = TypeStore (Map MetaPtr (TVar t))
  deriving (Functor, Monoid, Semigroup, Show)

type instance Index (TypeStore t) = MetaPtr
type instance IxValue (TypeStore t) = TVar t

instance Ixed (TypeStore t) where
  ix var f (TypeStore env) = TypeStore <$> ix var f env

instance At (TypeStore t) where
  at x f (TypeStore env) = TypeStore <$> at x f env

data Scheme t = Scheme Natural t deriving (Eq, Show)
makeLenses ''Scheme

newtype Ty = Ty
  { unTy :: TyF Ty }
  deriving (Eq, Show)
makePrisms ''Ty

instance AlphaEq a => AlphaEq (TyF a) where
  alphaCheck (TyF ctor1 args1) (TyF ctor2 args2) = do
    guard (ctor1 == ctor2)
    guard (length args1 == length args2)
    for_ (zip args1 args2) (uncurry alphaCheck)

instance ShortShow a => ShortShow (TyF a) where
  shortShow t = show (fmap shortShow t)


class TyLike a arg | a -> arg where
  tSyntax    :: a
  tSignal    :: a
  tString    :: a
  tFun1      :: arg -> arg -> a
  tMacro     :: arg -> a
  tType      :: a
  tDatatype  :: Datatype -> [arg] -> a
  tSchemaVar :: Natural -> a
  tMetaVar   :: MetaPtr -> a

instance TyLike (TyF a) a where
  tSyntax        = TyF TSyntax []
  tSignal        = TyF TSignal []
  tString        = TyF TString []
  tFun1 t1 t2    = TyF TFun [t1, t2]
  tMacro t       = TyF TMacro [t]
  tType          = TyF TType []
  tDatatype x ts = TyF (TDatatype x) ts
  tSchemaVar x   = TyF (TSchemaVar x) []
  tMetaVar x     = TyF (TMetaVar x) []

instance TyLike Ty Ty where
  tSyntax        = Ty $ tSyntax
  tSignal        = Ty $ tSignal
  tString        = Ty $ tString
  tFun1 t1 t2    = Ty $ tFun1 t1 t2
  tMacro t       = Ty $ tMacro t
  tType          = Ty $ tType
  tDatatype x ts = Ty $ tDatatype x ts
  tSchemaVar x   = Ty $ tSchemaVar x
  tMetaVar x     = Ty $ tMetaVar x

tFun :: [Ty] -> Ty -> Ty
tFun args result = foldr tFun1 result args
