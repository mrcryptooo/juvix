module MiniJuvix.Syntax.MicroJuvix.Language.Extra
  ( module MiniJuvix.Syntax.MicroJuvix.Language.Extra,
    module MiniJuvix.Syntax.MicroJuvix.Language,
  )
where

import Data.HashMap.Strict qualified as HashMap
import MiniJuvix.Prelude
import MiniJuvix.Syntax.MicroJuvix.Language

data Caller
  = CallerInductive InductiveName
  | CallerFunction FunctionName
  | CallerAxiom AxiomName
  deriving stock (Eq, Ord, Generic)

data TypeCallIden
  = InductiveIden InductiveName
  | FunctionIden FunctionName
  deriving stock (Eq, Ord, Generic)

data TypeCall' a = TypeCall'
  { _typeCallIden :: TypeCallIden,
    _typeCallArguments :: NonEmpty a
  }
  deriving stock (Eq, Generic)

newtype TypeCallsMap = TypeCallsMap
  { _typeCallsMap :: HashMap Caller (HashSet TypeCall)
  }

instance Functor TypeCall' where
  fmap f (TypeCall' i args) = TypeCall' i (fmap f args)

newtype ConcreteType = ConcreteType {_unconcreteType :: Type}
  deriving stock (Eq, Generic)

type ConcreteTypeCall = TypeCall' ConcreteType

type TypeCall = TypeCall' Type

type SubsE = HashMap VarName Expression

type Rename = HashMap VarName VarName

type Subs = HashMap VarName Type

type ConcreteSubs = HashMap VarName ConcreteType

-- | Indexed by _typeCallIden
newtype TypeCalls = TypeCalls
  { _typeCallSet :: HashMap TypeCallIden (HashMap ConcreteTypeCall ConcreteSubs)
  }

type VarMap = HashMap VarName VarName

emptyCalls :: TypeCalls
emptyCalls = TypeCalls mempty

instance Hashable TypeCallIden

instance Hashable TypeCall

instance Hashable Caller

instance Hashable ConcreteTypeCall

instance Hashable ConcreteType

makeLenses ''TypeCalls
makeLenses ''TypeCall'
makeLenses ''TypeCallsMap
makeLenses ''ConcreteType

typeCallIdenToCaller :: TypeCallIden -> Caller
typeCallIdenToCaller = \case
  InductiveIden i -> CallerInductive i
  FunctionIden i -> CallerFunction i

mkConcreteType' :: Type -> ConcreteType
mkConcreteType' =
  fromMaybe (error "the given type is not concrete")
    . mkConcreteType

mkConcreteType :: Type -> Maybe ConcreteType
mkConcreteType = fmap ConcreteType . go
  where
    go :: Type -> Maybe Type
    go t = case t of
      TypeApp (TypeApplication l r) -> do
        l' <- go l
        r' <- go r
        return (TypeApp (TypeApplication l' r'))
      TypeAny -> return TypeAny
      TypeUniverse -> return TypeUniverse
      TypeFunction (Function l r) -> do
        l' <- go l
        r' <- go r
        return (TypeFunction (Function l' r'))
      TypeAbs {} -> Nothing
      TypeIden i -> case i of
        TypeIdenInductive {} -> return t
        TypeIdenAxiom {} -> return t
        TypeIdenVariable {} -> Nothing

-- | unsafe version
expressionAsType' :: Expression -> Type
expressionAsType' = fromMaybe impossible . expressionAsType

-- | If the expression is of type TypeUniverse it should return Just.
expressionAsType :: Expression -> Maybe Type
expressionAsType = go
  where
    go = \case
      ExpressionIden i -> TypeIden <$> goIden i
      ExpressionApplication a -> TypeApp <$> goApp a
      ExpressionLiteral {} -> Nothing
      ExpressionFunction f -> TypeFunction <$> goFunction f
      ExpressionTyped e -> go (e ^. typedExpression)
    goFunction :: FunctionExpression -> Maybe Function
    goFunction (FunctionExpression l r) = do
      l' <- go l
      r' <- go r
      return (Function l' r')
    goIden :: Iden -> Maybe TypeIden
    goIden = \case
      IdenFunction {} -> Nothing
      IdenConstructor {} -> Nothing
      IdenVar v -> Just (TypeIdenVariable v)
      IdenAxiom a -> Just (TypeIdenAxiom a)
      IdenInductive i -> Just (TypeIdenInductive i)
    goApp :: Application -> Maybe TypeApplication
    goApp (Application l r) = do
      l' <- go l
      r' <- go r
      return (TypeApplication l' r')

substituteIndParams :: [(InductiveParameter, Type)] -> Type -> Type
substituteIndParams = substitution . HashMap.fromList . map (first (^. inductiveParamName))

substitutionArg :: VarName -> VarName -> FunctionArgType -> FunctionArgType
substitutionArg from v a = case a of
  FunctionArgTypeAbstraction {} -> a
  FunctionArgTypeType ty ->
    FunctionArgTypeType
      (substituteType1 (from, TypeIden (TypeIdenVariable v)) ty)

renameToSubsE :: Rename -> SubsE
renameToSubsE = fmap (ExpressionIden . IdenVar)

renameExpression :: Rename -> Expression -> Expression
renameExpression r = substitutionE (renameToSubsE r)

substituteType1 :: (VarName, Type) -> Type -> Type
substituteType1 = substitution . uncurry HashMap.singleton

patternVariables :: Pattern -> [VarName]
patternVariables = \case
  PatternVariable v -> [v]
  PatternConstructorApp a -> goApp a
  PatternWildcard -> []
  where
    goApp :: ConstructorApp -> [VarName]
    goApp (ConstructorApp _ ps) = concatMap patternVariables ps

renamePattern :: Rename -> Pattern -> Pattern
renamePattern m = go
  where
    go :: Pattern -> Pattern
    go p = case p of
      PatternVariable v
        | Just v' <- m ^. at v -> PatternVariable v'
      _ -> p

inductiveTypeVarsAssoc :: Foldable f => InductiveDef -> f a -> HashMap VarName a
inductiveTypeVarsAssoc def l
  | length vars < n = impossible
  | otherwise = HashMap.fromList (zip vars (toList l))
  where
    n = length l
    vars :: [VarName]
    vars = def ^.. inductiveParameters . each . inductiveParamName

functionTypeVarsAssoc :: forall a f. Foldable f => FunctionDef -> f a -> HashMap VarName a
functionTypeVarsAssoc def l = sig <> mconcatMap clause (def ^. funDefClauses)
  where
    n = length l
    zipl :: [Maybe VarName] -> HashMap VarName a
    zipl x = HashMap.fromList (mapMaybe aux (zip x (toList l)))
      where
        aux = \case
          (Just a, b) -> Just (a, b)
          _ -> Nothing
    sig
      | length tyVars < n = impossible
      | otherwise = zipl (map Just tyVars)
      where
        tyVars = fst (unfoldTypeAbsType (def ^. funDefType))
    clause :: FunctionClause -> HashMap VarName a
    clause c = zipl clauseVars
      where
        clauseVars :: [Maybe VarName]
        clauseVars = take n (map patternVar (c ^. clausePatterns))
          where
            patternVar :: Pattern -> Maybe VarName
            patternVar = \case
              PatternVariable v -> Just v
              _ -> Nothing

substitutionConcrete :: ConcreteSubs -> Type -> ConcreteType
substitutionConcrete m = mkConcreteType' . substitution ((^. unconcreteType) <$> m)

concreteTypeToExpr :: ConcreteType -> Expression
concreteTypeToExpr = go . (^. unconcreteType)
  where
    go :: Type -> Expression
    go = \case
      TypeAbs {} -> impossible
      TypeIden i -> ExpressionIden (goIden i)
      TypeApp (TypeApplication l r) -> ExpressionApplication (Application (go l) (go r))
      TypeFunction {} -> error "TODO"
      TypeUniverse {} -> impossible
      TypeAny {} -> impossible
    goIden :: TypeIden -> Iden
    goIden = \case
      TypeIdenInductive n -> IdenInductive n
      TypeIdenAxiom n -> IdenAxiom n
      TypeIdenVariable v -> IdenVar v

concreteSubsToSubsE :: ConcreteSubs -> SubsE
concreteSubsToSubsE = fmap concreteTypeToExpr

substitutionE :: SubsE -> Expression -> Expression
substitutionE m = go
  where
    go :: Expression -> Expression
    go x = case x of
      ExpressionIden i -> goIden i
      ExpressionApplication a -> ExpressionApplication (goApp a)
      ExpressionLiteral {} -> x
      ExpressionFunction f -> ExpressionFunction (goFunction f)
      ExpressionTyped t -> ExpressionTyped (over typedExpression go t)
    goApp :: Application -> Application
    goApp (Application l r) = Application (go l) (go r)
    goFunction :: FunctionExpression -> FunctionExpression
    goFunction (FunctionExpression l r) = FunctionExpression (go l) (go r)
    goIden :: Iden -> Expression
    goIden i = case i of
      IdenVar v
        | Just e <- HashMap.lookup v m -> e
      _ -> ExpressionIden i

substitution :: Subs -> Type -> Type
substitution m = go
  where
    go :: Type -> Type
    go = \case
      TypeIden i -> goIden i
      TypeApp a -> TypeApp (goApp a)
      TypeAbs a -> TypeAbs (goAbs a)
      TypeFunction f -> TypeFunction (goFunction f)
      TypeUniverse -> TypeUniverse
      TypeAny -> TypeAny
    goApp :: TypeApplication -> TypeApplication
    goApp (TypeApplication l r) = TypeApplication (go l) (go r)
    goAbs :: TypeAbstraction -> TypeAbstraction
    goAbs (TypeAbstraction v b) = TypeAbstraction v (go b)
    goFunction :: Function -> Function
    goFunction (Function l r) = Function (go l) (go r)
    goIden :: TypeIden -> Type
    goIden i = case i of
      TypeIdenInductive {} -> TypeIden i
      TypeIdenAxiom {} -> TypeIden i
      TypeIdenVariable v -> case HashMap.lookup v m of
        Just ty -> ty
        Nothing -> TypeIden i

-- | [a, b] c ==> a -> (b -> c)
foldFunType :: [FunctionArgType] -> Type -> Type
foldFunType l r = case l of
  [] -> r
  (a : as) ->
    let r' = foldFunType as r
     in case a of
          FunctionArgTypeAbstraction v -> TypeAbs (TypeAbstraction v r')
          FunctionArgTypeType t -> TypeFunction (Function t r')

-- | a -> (b -> c)  ==> ([a, b], c)
unfoldFunType :: Type -> ([FunctionArgType], Type)
unfoldFunType t = case t of
  TypeFunction (Function l r) -> first (FunctionArgTypeType l :) (unfoldFunType r)
  TypeAbs (TypeAbstraction var r) -> first (FunctionArgTypeAbstraction var :) (unfoldFunType r)
  _ -> ([], t)

unfoldTypeAbsType :: Type -> ([VarName], Type)
unfoldTypeAbsType t = case t of
  TypeAbs (TypeAbstraction var r) -> first (var :) (unfoldTypeAbsType r)
  _ -> ([], t)

foldApplication :: Expression -> [Expression] -> Expression
foldApplication f args = case args of
  [] -> f
  (a : as) -> foldApplication (ExpressionApplication (Application f a)) as

unfoldApplication :: Application -> (Expression, NonEmpty Expression)
unfoldApplication (Application l' r') = second (|: r') (unfoldExpression l')
  where
    unfoldExpression :: Expression -> (Expression, [Expression])
    unfoldExpression e = case e of
      ExpressionIden {} -> (e, [])
      ExpressionApplication (Application l r) ->
        second (`snoc` r) (unfoldExpression l)
      ExpressionLiteral {} -> (e, [])
      ExpressionFunction {} -> (e, [])
      ExpressionTyped t -> unfoldExpression (t ^. typedExpression)

unfoldTypeApplication :: TypeApplication -> (Type, NonEmpty Type)
unfoldTypeApplication (TypeApplication l' r') = second (|: r') (unfoldType l')
  where
    unfoldType :: Type -> (Type, [Type])
    unfoldType t = case t of
      TypeApp (TypeApplication l r) -> second (`snoc` r) (unfoldType l)
      _ -> (t, [])