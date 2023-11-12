module Juvix.Compiler.Internal.Translation.FromInternal.Analysis.TypeChecking.CheckerNew.Arity where

import Juvix.Compiler.Internal.Extra
import Juvix.Prelude
import Juvix.Prelude.Pretty

-- | Used to detect of cycles of default arguments in the arity checker.
newtype InsertedArgsStack = InsertedArgsStack
  { _insertedArgsStack :: [Name]
  }
  deriving newtype (Monoid, Semigroup)

-- | Helper type used during insertion of default arguments in the arity
-- checker.
data InsertedArg = InsertedArg
  { _insertedArgName :: Name,
    _insertedArg :: ApplicationArg,
    -- | True if this corresponds to an automatically inserted default argument.
    -- False if it is an inserted hole or an argument present in the source code.
    _insertedArgDefault :: Bool
  }

-- pattern ArityParam :: IsImplicit -> ArityParameter
-- pattern ArityParam impl <- ArityParameter {_arityParameterImplicit = impl}

data Blocking
  = BlockingVar VarName
  | BlockingHole Hole
  deriving stock (Show, Eq)

data Arity
  = ArityUnit
  | ArityFunction FunctionArity
  | ArityBlocking Blocking
  | ArityNotKnown
  | ArityError
  deriving stock (Eq)

data FunctionArity = FunctionArity
  { _functionArityLeft :: ArityParameter,
    _functionArityRight :: Arity
  }
  deriving stock (Eq)

data ArityRest
  = ArityRestUnit
  | ArityRestUnknown
  | ArityRestBlocking Blocking
  deriving stock (Eq)

data UnfoldedArity = UnfoldedArity
  { _ufoldArityParams :: [ArityParameter],
    _ufoldArityRest :: ArityRest
  }
  deriving stock (Eq)

data ArityParameter = ArityParameter
  { _arityParameterArity :: Arity,
    _arityParameterImplicit :: IsImplicit,
    _arityParameterInfo :: ArgInfo
  }

instance Eq ArityParameter where
  (ArityParameter ari impl _info) == (ArityParameter ari' impl' _info') =
    (ari, impl) == (ari', impl')

makeLenses ''UnfoldedArity
makeLenses ''FunctionArity
makeLenses ''InsertedArg
makeLenses ''ArityParameter
makeLenses ''InsertedArgsStack

arityParameterName :: Lens' ArityParameter (Maybe Name)
arityParameterName = arityParameterInfo . argInfoName

unfoldingArity :: (UnfoldedArity -> UnfoldedArity) -> Arity -> Arity
unfoldingArity f = foldArity . f . unfoldArity'

arityParameter :: ArityParameter -> Arity
arityParameter = (^. arityParameterArity)

arityParameterImplicitOrInstance :: ArityParameter -> Bool
arityParameterImplicitOrInstance a = case a ^. arityParameterImplicit of
  Explicit {} -> False
  Implicit {} -> True
  ImplicitInstance -> True

arityCommonPrefix :: Arity -> Arity -> [ArityParameter]
arityCommonPrefix p1 p2 = commonPrefix u1 u2
  where
    u1 = unfoldArity p1
    u2 = unfoldArity p2

unfoldArity' :: Arity -> UnfoldedArity
unfoldArity' = \case
  ArityError -> notKnown
  ArityNotKnown -> notKnown
  ArityUnit ->
    UnfoldedArity
      { _ufoldArityParams = [],
        _ufoldArityRest = ArityRestUnit
      }
  ArityBlocking v ->
    UnfoldedArity
      { _ufoldArityParams = [],
        _ufoldArityRest = ArityRestBlocking v
      }
  ArityFunction (FunctionArity l r) ->
    over ufoldArityParams (l :) (unfoldArity' r)
  where
    notKnown :: UnfoldedArity
    notKnown =
      UnfoldedArity
        { _ufoldArityParams = [],
          _ufoldArityRest = ArityRestUnknown
        }

unfoldArity :: Arity -> [ArityParameter]
unfoldArity = (^. ufoldArityParams) . unfoldArity'

foldArity :: UnfoldedArity -> Arity
foldArity UnfoldedArity {..} = go _ufoldArityParams
  where
    go :: [ArityParameter] -> Arity
    go = \case
      [] -> case _ufoldArityRest of
        ArityRestUnit -> ArityUnit
        ArityRestUnknown -> ArityNotKnown
        ArityRestBlocking v -> ArityBlocking v
      (a : as) -> ArityFunction (FunctionArity a (go as))

instance HasAtomicity FunctionArity where
  atomicity = const (Aggregate funFixity)

instance HasAtomicity Arity where
  atomicity = \case
    ArityUnit -> Atom
    ArityBlocking {} -> Atom
    ArityError {} -> Atom
    ArityFunction f -> atomicity f
    ArityNotKnown {} -> Atom

instance Pretty ArityParameter where
  pretty a =
    let ari = arityParameter a
     in case a ^. arityParameterImplicit of
          Implicit -> "{" <> pretty ari <> "}"
          ImplicitInstance -> "{{𝟙}}"
          Explicit -> pretty ari

instance Pretty FunctionArity where
  pretty f@(FunctionArity l r) =
    parensCond (atomParens (const True) (atomicity f) funFixity) (pretty l)
      <> " → "
      <> pretty r
    where
      parensCond :: Bool -> Doc a -> Doc a
      parensCond t d = if t then parens d else d

instance Pretty Blocking where
  pretty = \case
    BlockingVar v -> pretty v
    BlockingHole h -> pretty h

instance Pretty Arity where
  pretty = \case
    ArityUnit -> "𝟙"
    ArityBlocking v -> "?@" <> pretty v
    ArityFunction f -> pretty f
    ArityError -> "err"
    ArityNotKnown -> "?"