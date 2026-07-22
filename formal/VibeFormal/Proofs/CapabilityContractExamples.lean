import VibeFormal.Proofs.CapabilityContractCorrect

set_option autoImplicit false

namespace VibeFormal.Capability.Examples

private def s3Effect : EffectDefId := ⟨"vibe/cloud", "s3", 0⟩
private def httpEffect : EffectDefId := ⟨"vibe/std", "http", 0⟩

private def s3GetPosts : OperationRef :=
  ⟨⟨s3Effect, 0⟩, [.resourceId 0]⟩

private def s3PutPosts : OperationRef :=
  ⟨⟨s3Effect, 1⟩, [.resourceId 0]⟩

private def s3GetUploads : OperationRef :=
  ⟨⟨s3Effect, 0⟩, [.resourceId 1]⟩

private def httpRequest : OperationRef :=
  ⟨⟨httpEffect, 0⟩, []⟩

private def postsClaim : ResourceClaim :=
  { resource := ⟨0⟩, kind := ⟨0⟩ }

private def postsBinding : ResourceBinding :=
  { resource := ⟨0⟩, kind := ⟨0⟩ }

private def uploadsBinding : ResourceBinding :=
  { resource := ⟨1⟩, kind := ⟨0⟩ }

private def readEntry : EntryContract :=
  { requires := [s3GetPosts]
    forkRequires := [s3GetPosts]
    resources := [postsClaim] }

private def fullHost : HostProfile :=
  { provides := [s3GetPosts, s3PutPosts]
    forkable := [s3GetPosts, s3PutPosts]
    bindings := [postsBinding] }

private def missingS3Host : HostProfile :=
  { provides := [httpRequest]
    forkable := [httpRequest]
    bindings := [postsBinding] }

example : readEntry.runnable fullHost = true := by
  decide

/-- A host import is not a semantic S3 implementation until a provider is linked. -/
example : readEntry.runnable missingS3Host = false := by
  decide

/-- A binding for another logical bucket does not satisfy the Posts claim. -/
example :
    readEntry.runnable { fullHost with bindings := [uploadsBinding] } = false := by
  decide

private def s3ViaHttp : Provider :=
  { handles := [s3GetPosts]
    requires := [httpRequest] }

/-- S3 is lowered through a provider; it is not a subtype of Http. -/
example : s3ViaHttp.lower [s3GetPosts] = [httpRequest] := by
  decide

/-- Child authority is narrowed from the parent, not inherited from the host. -/
example : canSpawn fullHost [s3GetPosts] [s3PutPosts] = false := by
  decide

private def brokenAmbientSpawn
    (host : HostProfile)
    (child : Authority) : Bool :=
  EffectRow.subset child host.provides

/-- The rejected ambient-inheritance rule exposes the escalation witness. -/
example : brokenAmbientSpawn fullHost [s3PutPosts] = true := by
  decide

private def serialWriteHost : HostProfile :=
  { fullHost with forkable := [s3GetPosts] }

/-- Provider availability alone is insufficient when its evidence is task-local. -/
example : canSpawn serialWriteHost [s3PutPosts] [s3PutPosts] = false := by
  decide

/-- A fork-safe read child may use exactly the authority delegated by its parent. -/
example : canSpawn fullHost [s3GetPosts] [s3GetPosts] = true := by
  decide

abbrev DemoWorld := Async.World Bool Unit Unit Unit
abbrev DemoMachine := Parallel.Machine Bool Bool Unit Unit Unit

private def emptyWorld : DemoWorld :=
  { tasks := fun _ => none
    nurseries := fun _ => none }

private def firstWorkerMachine : DemoMachine :=
  { world := emptyWorld
    workers := fun worker =>
      if worker = false then .running false else .idle }

private def secondWorkerMachine : DemoMachine :=
  { world := emptyWorld
    workers := fun worker =>
      if worker = true then .running false else .idle }

private def taskAuthority (task : Bool) : Authority :=
  if task = false then [s3GetPosts] else []

/-- Moving a task between physical workers preserves its task-owned authority. -/
example :
    WorkerMayPerform firstWorkerMachine taskAuthority false s3GetPosts ∧
      WorkerMayPerform secondWorkerMachine taskAuthority true s3GetPosts := by
  constructor
  · exact ⟨false, by simp [firstWorkerMachine, Parallel.Machine.Owns], by simp [taskAuthority]⟩
  · exact ⟨false, by simp [secondWorkerMachine, Parallel.Machine.Owns], by simp [taskAuthority]⟩

end VibeFormal.Capability.Examples
