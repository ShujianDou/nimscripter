import std/[macros, macrocache, typetraits]
import compiler/[vmdef, vm, ast]
import vmconversion

import procsignature
export VmProcSignature

func deSym*(n: NimNode): NimNode =
  # Remove all symbols
  result = n
  for x in 0 .. result.len - 1:
    if result[x].kind == nnkSym:
      result[x] = ident($result[x])
    else:
      result[x] = result[x].deSym

func getMangledName*(pDef: NimNode): string =
  ## Generates a close to type safe name for backers
  result = $pdef[0]
  for def in pDef[3][1..^1]:
    for idnt in def[0..^3]:
      result.add $idnt
    if def[^2].kind in {nnkSym, nnkIdent}:
      result.add $def[^2]
  result.add "Comp"

func getVmRuntimeImpl*(pDef: NimNode): string =
  ## Returns the nimscript code that will convert to string and return the value.
  ## This does the interop and where we want a serializer if we ever can.
  let deSymd = deSym(pDef.copyNimTree())
  deSymd[^1] = nnkDiscardStmt.newTree(newEmptyNode())
  deSymd[^2] = nnkDiscardStmt.newTree(newEmptyNode())
  deSymd.repr

proc getReg(vmargs: Vmargs, pos: int): TFullReg = vmargs.slots[pos + vmargs.rb + 1]

proc getLambda*(pDef: NimNode): NimNode =
  ## Generates the lambda for the vm backed logic.
  ## This is what the vm calls internally when talking to Nim
  let
    vmArgs = ident"vmArgs"
    tmp = quote do:
      proc n(`vmArgs`: VmArgs){.closure, gcsafe.} = discard

  tmp[^1] = newStmtList()

  tmp[0] = newEmptyNode()
  result = nnkLambda.newNimNode()
  tmp.copyChildrenTo(result)

  var procArgs: seq[NimNode]
  for def in pDef.params[1..^1]:
    let typ = def[^2]
    for idnt in def[0..^3]: # Get data from buffer in the vm proc
      let
        idnt = ident($idnt)
        argNum = newLit(procArgs.len)
      procArgs.add idnt
      result[^1].add quote do:
        let reg = getReg(`vmArgs`, `argNum`)
        var `idnt`: `typ`
        when `typ` is (SomeOrdinal or enum):
          case reg.kind:
          of rkInt:
            `idnt` = `typ`(reg.intVal)
          of rkNode:
            `idnt` = fromVm(typeof(`typ`), reg.node)
          else: discard
        elif `typ` is SomeFloat:
          case reg.kind:
          of rkFloat:
            `idnt` = `typ`(reg.floatVal)
          of rkNode:
            `idnt` = fromVm(typeof(`typ`), reg.node)
          else: discard
        else:
          `idnt` = fromVm(typeof(`typ`), getNode(`vmArgs`, `argNum`))
  if pdef.params.len > 1:
    result[^1].add newCall(pDef[0], procArgs)
  else:
    result[^1].add newCall(pDef[0])
  if pdef.params[0].kind != nnkEmpty:
    let
      retT = pDef.params[0]
      call = result[^1][^1]
    result[^1][^1] = quote do:
      when `retT` is (SomeOrdinal or enum):
        `vmArgs`.setResult(BiggestInt(`call`))
      elif `retT` is SomeFloat:
        `vmArgs`.setResult(BiggestFloat(`call`))
      elif `retT` is string:
        `vmArgs`.setResult(`call`)
      else:
        `vmArgs`.setResult(toVm(`call`))

const procedureCache = CacheTable"NimscriptProcedures"

proc addToCache(n: NimNode, moduleName: string) = 
  for name, _ in procedureCache:
    if name == moduleName:
      procedureCache[name].add n
      return
  procedureCache[moduleName] = nnkStmtList.newTree(n)

macro exportToScript*(moduleName: untyped, procedure: typed): untyped =
  result = procedure
  if procedure.kind == nnkProcDef:
    addToCache(procedure, $moduleName)
  else:
    error("Use `exportTo` for block definitions, `exportToScript` is for proc defs only", procedure)

macro exportTo*(moduleName: static string, procDefs: typed): untyped =
  for pDef in procDefs:
    if pdef.kind == nnkProcDef:
      addToCache(pDef, moduleName)
  result = procDefs

macro implNimscriptModule*(moduleName: untyped): untyped =
  moduleName.expectKind(nnkIdent)
  result = nnkBracket.newNimNode()
  for p in procedureCache[$moduleName]:
    let
      runImpl = getVmRuntimeImpl(p)
      lambda = getLambda(p)
      realName = $p[0]
    result.add quote do:
      VmProcSignature(
        name: `realName`,
        vmRunImpl: `runImpl`,
        vmProc: `lambda`
      )
