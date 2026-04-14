import Lake
open Lake DSL

require aeneas from git
  "https://github.com/AeneasVerif/aeneas" @ "864eddb4876d0104802e0fd29bd453f67f48c4be" / "backends" / "lean"

package «consensus-lean4» {}

@[default_target] lean_lib «ConsensusLean4» {}
