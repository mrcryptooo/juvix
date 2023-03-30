module Commands.Dev.Core.Compile.Base where

import Commands.Base
import Commands.Dev.Core.Compile.Options
import Commands.Extra.Compile qualified as Compile
import Data.Text.IO qualified as TIO
import Juvix.Compiler.Asm.Pretty qualified as Asm
import Juvix.Compiler.Backend qualified as Backend
import Juvix.Compiler.Backend.C qualified as C
import Juvix.Compiler.Backend.Geb qualified as Geb
import Juvix.Compiler.Core.Data.InfoTable qualified as Core
import System.FilePath (takeBaseName)

data PipelineArg = PipelineArg
  { _pipelineArgOptions :: CompileOptions,
    _pipelineArgFile :: Path Abs File,
    _pipelineArgInfoTable :: Core.InfoTable
  }

getEntry :: Members '[Embed IO, App] r => PipelineArg -> Sem r EntryPoint
getEntry PipelineArg {..} = do
  ep <- getEntryPoint (AppPath (Abs _pipelineArgFile) True)
  return $
    ep
      { _entryPointTarget = getTarget (_pipelineArgOptions ^. compileTarget),
        _entryPointDebug = _pipelineArgOptions ^. compileDebug
      }
  where
    getTarget :: CompileTarget -> Backend.Target
    getTarget = \case
      TargetWasm32Wasi -> Backend.TargetCWasm32Wasi
      TargetNative64 -> Backend.TargetCNative64
      TargetGeb -> Backend.TargetGeb
      TargetCore -> Backend.TargetCore
      TargetAsm -> Backend.TargetAsm

runCPipeline ::
  forall r.
  (Members '[Embed IO, App] r) =>
  PipelineArg ->
  Sem r ()
runCPipeline pa@PipelineArg {..} = do
  entryPoint <- getEntry pa
  C.MiniCResult {..} <- getRight (run (runReader entryPoint (runError (coreToMiniC _pipelineArgInfoTable :: Sem '[Error JuvixError, Reader EntryPoint] C.MiniCResult))))
  cFile <- inputCFile _pipelineArgFile
  embed $ TIO.writeFile (toFilePath cFile) _resultCCode
  outfile <- Compile.outputFile _pipelineArgOptions _pipelineArgFile
  Compile.runCommand
    _pipelineArgOptions
      { _compileInputFile = AppPath (Abs cFile) False,
        _compileOutputFile = Just (AppPath (Abs outfile) False)
      }
  where
    inputCFile :: Path Abs File -> Sem r (Path Abs File)
    inputCFile inputFileCompile = do
      buildDir <- askBuildDir
      ensureDir buildDir
      return (buildDir <//> replaceExtension' ".c" (filename inputFileCompile))

runGebPipeline ::
  forall r.
  (Members '[Embed IO, App] r) =>
  PipelineArg ->
  Sem r ()
runGebPipeline pa@PipelineArg {..} = do
  entryPoint <- getEntry pa
  gebFile <- Compile.outputFile _pipelineArgOptions _pipelineArgFile
  let spec =
        if
            | _pipelineArgOptions ^. compileTerm -> Geb.OnlyTerm
            | otherwise ->
                Geb.LispPackage
                  Geb.LispPackageSpec
                    { _lispPackageName = fromString $ takeBaseName $ toFilePath gebFile,
                      _lispPackageEntry = "*entry*"
                    }
  Geb.Result {..} <- getRight (run (runReader entryPoint (runError (coreToGeb spec _pipelineArgInfoTable :: Sem '[Error JuvixError, Reader EntryPoint] Geb.Result))))
  embed $ TIO.writeFile (toFilePath gebFile) _resultCode

runAsmPipeline :: (Members '[Embed IO, App] r) => PipelineArg -> Sem r ()
runAsmPipeline pa@PipelineArg {..} = do
  entryPoint <- getEntry pa
  asmFile <- Compile.outputFile _pipelineArgOptions _pipelineArgFile
  r <- runReader entryPoint $ runError @JuvixError (coreToAsm _pipelineArgInfoTable)
  tab' <- getRight r
  let code = Asm.ppPrint tab' tab'
  embed $ TIO.writeFile (toFilePath asmFile) code