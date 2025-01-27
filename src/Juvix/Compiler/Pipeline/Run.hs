module Juvix.Compiler.Pipeline.Run
  ( module Juvix.Compiler.Pipeline.Run,
    module Juvix.Compiler.Pipeline,
  )
where

import Juvix.Compiler.Builtins
import Juvix.Compiler.Concrete.Data.Highlight
import Juvix.Compiler.Concrete.Data.ParsedInfoTableBuilder.BuilderState qualified as Concrete
import Juvix.Compiler.Concrete.Data.Scope
import Juvix.Compiler.Concrete.Translation.FromParsed.Analysis.PathResolver
import Juvix.Compiler.Concrete.Translation.FromParsed.Analysis.Scoping qualified as Scoped
import Juvix.Compiler.Concrete.Translation.FromParsed.Analysis.Scoping qualified as Scoper
import Juvix.Compiler.Concrete.Translation.FromSource qualified as P
import Juvix.Compiler.Core.Data.InfoTable qualified as Core
import Juvix.Compiler.Core.Translation.FromInternal.Data qualified as Core
import Juvix.Compiler.Internal.Translation qualified as Internal
import Juvix.Compiler.Internal.Translation.FromInternal.Analysis.Termination
import Juvix.Compiler.Internal.Translation.FromInternal.Analysis.TypeChecking qualified as Typed
import Juvix.Compiler.Pipeline
import Juvix.Compiler.Pipeline.Artifacts.PathResolver
import Juvix.Compiler.Pipeline.Package.Loader.Error
import Juvix.Compiler.Pipeline.Package.Loader.EvalEff.IO
import Juvix.Compiler.Pipeline.Package.Loader.PathResolver
import Juvix.Data.Effect.Git
import Juvix.Data.Effect.Process
import Juvix.Data.Effect.TaggedLock
import Juvix.Prelude

runPipelineHighlight :: forall r a. (Members '[TaggedLock, Embed IO] r) => EntryPoint -> Sem (PipelineEff r) a -> Sem r HighlightInput
runPipelineHighlight entry = fmap fst . runIOEither entry

-- | It returns `ResolverState` so that we can retrieve the `juvix.yaml` files,
-- which we require for `Scope` tests.
runIOEither :: forall a r. (Members '[TaggedLock, Embed IO] r) => EntryPoint -> Sem (PipelineEff r) a -> Sem r (HighlightInput, (Either JuvixError (ResolverState, a)))
runIOEither entry = do
  let hasInternet = not (entry ^. entryPointOffline)
      runPathResolver'
        | mainIsPackageFile entry = runPackagePathResolver' (entry ^. entryPointResolverRoot)
        | otherwise = runPathResolverPipe
  evalInternet hasInternet
    . runHighlightBuilder
    . runJuvixError
    . evalTopBuiltins
    . evalTopNameIdGen
    . runFilesIO
    . runReader entry
    . runLogIO
    . runProcessIO
    . mapError (JuvixError @GitProcessError)
    . runGitProcess
    . mapError (JuvixError @DependencyError)
    . mapError (JuvixError @PackageLoaderError)
    . runEvalFileEffIO
    . runPathResolver'

mainIsPackageFile :: EntryPoint -> Bool
mainIsPackageFile entry = case entry ^? entryPointModulePaths . _head of
  Just p -> p == mkPackagePath (entry ^. entryPointResolverRoot)
  Nothing -> False

runIO :: forall a r. (Members '[TaggedLock, Embed IO] r) => GenericOptions -> EntryPoint -> Sem (PipelineEff r) a -> Sem r (ResolverState, a)
runIO opts entry = runIOEither entry >=> mayThrow . snd
  where
    mayThrow :: (Members '[Embed IO] r') => Either JuvixError x -> Sem r' x
    mayThrow = \case
      Left err -> runReader opts $ printErrorAnsiSafe err >> embed exitFailure
      Right r -> return r

corePipelineIO' :: EntryPoint -> IO Artifacts
corePipelineIO' = corePipelineIO defaultGenericOptions

corePipelineIO :: GenericOptions -> EntryPoint -> IO Artifacts
corePipelineIO opts entry = corePipelineIOEither entry >>= mayThrow
  where
    mayThrow :: Either JuvixError r -> IO r
    mayThrow = \case
      Left err -> runM . runReader opts $ printErrorAnsiSafe err >> embed exitFailure
      Right r -> return r

corePipelineIOEither ::
  EntryPoint ->
  IO (Either JuvixError Artifacts)
corePipelineIOEither = corePipelineIOEither' LockModePermissive

corePipelineIOEither' ::
  LockMode ->
  EntryPoint ->
  IO (Either JuvixError Artifacts)
corePipelineIOEither' lockMode entry = do
  let hasInternet = not (entry ^. entryPointOffline)
      runPathResolver'
        | mainIsPackageFile entry = runPackagePathResolverArtifacts (entry ^. entryPointResolverRoot)
        | otherwise = runPathResolverArtifacts
  eith <-
    runFinal
      . resourceToIOFinal
      . embedToFinal @IO
      . evalInternet hasInternet
      . ignoreHighlightBuilder
      . runError
      . runState initialArtifacts
      . runBuiltinsArtifacts
      . runNameIdGenArtifacts
      . runFilesIO
      . runReader entry
      . runTaggedLock lockMode
      . runLogIO
      . mapError (JuvixError @GitProcessError)
      . runProcessIO
      . runGitProcess
      . mapError (JuvixError @DependencyError)
      . mapError (JuvixError @PackageLoaderError)
      . runEvalFileEffIO
      . runPathResolver'
      $ upToCore
  return $ case eith of
    Left err -> Left err
    Right (art, coreRes) ->
      let typedResult :: Internal.InternalTypedResult
          typedResult =
            coreRes
              ^. Core.coreResultInternalTypedResult

          typesTable :: Typed.TypesTable
          typesTable = typedResult ^. Typed.resultIdenTypes

          functionsTable :: Typed.FunctionsTable
          functionsTable = typedResult ^. Typed.resultFunctions

          typedTable :: Internal.InfoTable
          typedTable = typedResult ^. Typed.resultInfoTable

          internalResult :: Internal.InternalResult
          internalResult =
            typedResult
              ^. Typed.resultInternalResult

          coreTable :: Core.InfoTable
          coreTable = coreRes ^. Core.coreResultTable

          scopedResult :: Scoped.ScoperResult
          scopedResult =
            internalResult
              ^. Internal.resultScoper

          parserResult :: P.ParserResult
          parserResult = scopedResult ^. Scoped.resultParserResult

          resultScoperTable :: Scoped.InfoTable
          resultScoperTable = scopedResult ^. Scoped.resultScoperTable

          mainModuleScope_ :: Scope
          mainModuleScope_ = Scoped.mainModuleSope scopedResult
       in Right $
            Artifacts
              { _artifactMainModuleScope = Just mainModuleScope_,
                _artifactParsing = parserResult ^. P.resultBuilderState,
                _artifactInternalModuleCache = internalResult ^. Internal.resultModulesCache,
                _artifactInternalTypedTable = typedTable,
                _artifactTerminationState = typedResult ^. Typed.resultTermination,
                _artifactCoreTable = coreTable,
                _artifactScopeTable = resultScoperTable,
                _artifactScopeExports = scopedResult ^. Scoped.resultExports,
                _artifactTypes = typesTable,
                _artifactFunctions = functionsTable,
                _artifactScoperState = scopedResult ^. Scoped.resultScoperState,
                _artifactResolver = art ^. artifactResolver,
                _artifactBuiltins = art ^. artifactBuiltins,
                _artifactNameIdState = art ^. artifactNameIdState
              }
  where
    initialArtifacts :: Artifacts
    initialArtifacts =
      Artifacts
        { _artifactParsing = Concrete.iniState,
          _artifactMainModuleScope = Nothing,
          _artifactInternalTypedTable = mempty,
          _artifactTypes = mempty,
          _artifactTerminationState = iniTerminationState,
          _artifactResolver = iniResolverState,
          _artifactNameIdState = allNameIds,
          _artifactFunctions = mempty,
          _artifactCoreTable = Core.emptyInfoTable,
          _artifactScopeTable = Scoped.emptyInfoTable,
          _artifactBuiltins = iniBuiltins,
          _artifactScopeExports = mempty,
          _artifactInternalModuleCache = Internal.ModulesCache mempty,
          _artifactScoperState = Scoper.iniScoperState
        }
