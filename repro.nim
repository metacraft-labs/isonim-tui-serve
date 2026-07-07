## Reprobuild project file for isonim-tui-serve.
##
## **Typed-Cross-Project-Deps rollout leaf.** ``isonim-tui-serve`` is the
## WebSocket bridge for isonim-tui's M26 packet driver — a hand-rolled
## RFC 6455 frame codec (``src/isonim_tui_serve/wsframe.nim``), a
## self-contained D/M/P packet codec (``src/isonim_tui_serve/packet.nim``),
## a story-dispatch overlay on that transport
## (``src/isonim_tui_serve/story_dispatch.nim``), and the async server that
## bridges a hosted TUI child process to a browser tab
## (``src/isonim_tui_serve.nim``).
##
## Despite its name, this repo is a **pure-Nim LEAF**, not a cross-repo
## consumer. Its nimble file only ``requires "nim >= 2.0.0"``; every
## importable module lives under this repo's own ``src/`` tree, and every
## test ``import isonim_tui_serve`` (the umbrella at ``src/isonim_tui_serve.nim``
## which re-exports ``packet``, ``wsframe`` and ``story_dispatch``). No test
## or source file imports a workspace SIBLING — the packet wire shape is a
## SELF-CONTAINED re-implementation of what ``isonim-tui``'s
## ``web_driver.nim`` speaks (documented deliberately in ``AGENTS.md``:
## "Self-contained packet codec … the same D/M/P wire shape"), NOT a
## build-time ``import`` of that repo. So the ``uses:`` block is just the
## toolchain floor — there is no ``uses: "<sibling>"`` edge and the lock is
## self-only.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical ``runquota/repro.nim`` and the just-landed
## ``nim-pty/repro.nim`` / ``nim-libvterm/repro.nim`` /
## ``nim-stackable-hooks/repro.nim`` leaf recipes:
##
## * Declares the upstream tool floor via ``uses:`` so any future consumer
##   picks up the same toolchain the nimble file's
##   ``requires "nim >= 2.0.0"`` implies.
## * Declares ``library isonim_tui_serve`` so a consumer can express a
##   workspace dependency on this repo. The importable umbrella is
##   ``src/isonim_tui_serve.nim`` (consumers ``import isonim_tui_serve``); the
##   submodules under ``src/isonim_tui_serve/`` are importable too.
## * Emits, per runnable test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>`` and
##   an EXECUTE edge (``edge.testBinary.run``) that runs it — the two-edge
##   test template from ``reprobuild-specs/Package-Model.md`` §"The test
##   template". BUILD halves collect into ``test-builds``; EXECUTE halves
##   collect into ``test`` so ``repro build test`` / ``repro test``
##   materialise the runnable closure (each execute edge transitively
##   depends on its build edge).
##
## **Module search path + compile flags.** isonim-tui-serve ships no
## ``config.nims`` / ``nim.cfg``; its ``Justfile`` supplies
## ``--path:src --path:tests`` on every ``nim c``. ``--path:src`` is
## load-bearing (``import isonim_tui_serve``); ``--path:tests`` is carried
## too (harmless — no test imports another test module, but it mirrors the
## repo's own invocation), so each BUILD edge passes
## ``paths = @["src", "tests"]``. ``src`` is added to ``extraInputs`` so the
## whole module tree is a declared input of every compile.
##
## Each BUILD edge reproduces the repo's DEFAULT matrix point —
## ``just test`` → ``test-orc`` → ``_matrix orc release on`` →
## ``nim c … --mm:orc -d:release --threads:on``: ``--mm:orc`` via ``mm:``,
## ``-d:release`` via ``defines:``, and ``--threads:on`` via the wrapper's
## default ``threadsOn`` (this repo's async server + subprocess bridge use
## ``asyncdispatch``, so ``--threads:on`` is meaningful). The
## ``--styleCheck:usages --styleCheck:error`` switches from ``nim-flags``
## are style toggles that don't change the produced binary and aren't part
## of the typed ``nim c`` surface, so they're omitted — the corpus compiles
## + runs identically.
##
## **Per-test platform gating.** Enumerating EVERY ``tests/*.nim`` and
## re-deriving each file's guards from its imports (the ``Justfile``
## ``tests`` list names only three of the five suites — it is stale w.r.t.
## the two RS-M13 round-trip suites, which are real ``suite`` tests and are
## included here):
##
##   * ``test_serve_packet_framing`` / ``test_serve_wsframe_round_trip`` /
##     ``test_serve_element_tree_roundtrip`` / ``test_serve_select_story_roundtrip``
##     — pure ``unittest`` codec round-trips (``import std/[…] + isonim_tui_serve``,
##     no I/O, no OS ``when``). Compile + run to exit 0 on every host,
##     including this Linux host. Unconditionally in the graph.
##   * ``test_serve_packet_bridge`` — the end-to-end integration test. It
##     guards its single ``test`` body with
##     ``when defined(windows): skip() else: <real body>``, so it COMPILES
##     everywhere but only exercises the bridge on POSIX. The non-Windows
##     arm spawns a real ``echo_packet_app`` subprocess (compiling it on
##     first run via ``nim c``), binds an async server on an ephemeral
##     port, and drives a hand-rolled WebSocket client. On this Linux host
##     it runs the real round-trip to exit 0. It is in the graph
##     unconditionally (it compiles on all hosts; the in-``test`` guard is
##     the file's own concern, exactly as ``nim-pty``'s
##     ``test_pty_cross_platform`` handles its Windows arm).
##   * ``echo_packet_app.nim`` — a runnable FIXTURE (``import isonim_tui_serve``,
##     a ``proc main()`` stdin/stdout echo child), NOT a ``suite`` test. It
##     is compiled on demand by ``test_serve_packet_bridge`` at run time
##     (``nim c … -o:tests/echo_packet_app``) and is never listed in the
##     repo's ``tests`` set. It therefore gets NO edge here — only a
##     transitive runtime input of the bridge test.
##
## No test file in this repo is host-EXCLUSIVE to a non-Linux OS: every one
## either has no OS gate or an in-``test`` ``when defined(windows): skip()
## else: <real body>``, so all five suites are in the Linux graph and there
## are no ``when defined(...)`` extraction gates needed on this host.
##
## **Subprocess serialization.** ``test_serve_packet_bridge`` forks a real
## child process, binds a real listening socket on a best-effort ephemeral
## port, and drives a live async WebSocket handshake with sub-second poll
## windows. Under a saturated host during the cross-repo rollout, running
## it concurrently with everything else starves the child + the async
## dispatcher and races the ephemeral-port pick. It is routed through a
## capacity-1 build pool so it runs with the scheduler headroom its
## fork+exec + socket timing needs. This changes ONLY scheduling — no
## ``check`` is skipped, relaxed, or removed; the test still runs in full
## to exit 0. The pure-codec execute edges and every BUILD (compile) edge
## stay unpooled and parallel.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``
## (``nim`` is also needed at RUN time by the bridge test to compile its
## fixture), so the weak-local PATH resolver is the right default. Without
## it ``repro build`` refuses to run with "typed tool provisioning is
## required for uses declarations".

import repro_project_dsl

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by every test BUILD edge and the ``edge.testBinary.run(...)``
# UFCS dispatch for the EXECUTE edges. It re-exports ``repro_project_dsl`` so
# the import order is unimportant. Like the ``nim-pty`` / ``nim-libvterm``
# leaf recipes this file does NOT import ``ct_test_runner_install`` (that
# module is engine-coupled and reprobuild-internal): the execute edges route
# through the engine's default direct-binary runner (run the binary, key on
# exit status), which is exactly the exit-0 verification this corpus needs —
# Nim ``unittest`` prints per-suite results and exits non-zero on failure.
import ct_test_nim_unittest

type
  ServeTestSpec = object
    ## One entry per runnable test file. ``source`` is the repo-relative
    ## ``.nim`` path; ``binary`` is the ``build/test-bin/<stem>`` output.
    ## ``pool`` names the serialization pool (empty = unpooled/parallel).
    source: string
    binary: string
    pool: string

const bridgePool = "isonim_tui_serve.bridge-serial"

const serveTestSpecs: seq[ServeTestSpec] = @[
  # Pure codec round-trips — no I/O, no OS gate. Run in parallel.
  ServeTestSpec(source: "tests/test_serve_packet_framing.nim",
    binary: "build/test-bin/test_serve_packet_framing", pool: ""),
  ServeTestSpec(source: "tests/test_serve_wsframe_round_trip.nim",
    binary: "build/test-bin/test_serve_wsframe_round_trip", pool: ""),
  ServeTestSpec(source: "tests/test_serve_element_tree_roundtrip.nim",
    binary: "build/test-bin/test_serve_element_tree_roundtrip", pool: ""),
  ServeTestSpec(source: "tests/test_serve_select_story_roundtrip.nim",
    binary: "build/test-bin/test_serve_select_story_roundtrip", pool: ""),
  # End-to-end bridge integration — spawns a real subprocess + async
  # server on an ephemeral port. Serialized through a capacity-1 pool so
  # its fork+exec + socket timing runs with headroom (no check weakened).
  # In-``test`` ``when defined(windows): skip() else: <body>`` — compiles
  # everywhere, runs the real round-trip on this POSIX host.
  ServeTestSpec(source: "tests/test_serve_packet_bridge.nim",
    binary: "build/test-bin/test_serve_packet_bridge", pool: bridgePool),
]

package isonim_tui_serve:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs.
    # ``nim`` compiles every test binary (the ``buildNimUnittest.build``
    # edges below, matching the nimble file's ``requires "nim >= 2.0.0"``)
    # and is also invoked at RUN time by ``test_serve_packet_bridge`` to
    # compile its ``echo_packet_app`` fixture; ``gcc`` is the C back-end
    # ``nim c`` shells out to and links through. Sufficient for the
    # path-mode resolver under ``nix develop``.
    "nim >=2.0"
    "gcc >=12"

  # Library declaration — the ``src/`` tree the tests put on ``--path`` is
  # importable when this package is consumed via ``uses: "isonim_tui_serve"``.
  # The umbrella is ``src/isonim_tui_serve.nim`` (it re-exports ``packet``,
  # ``wsframe`` and ``story_dispatch``); consumers ``import isonim_tui_serve``.
  library isonim_tui_serve

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile BUILD edge + one EXECUTE edge per runnable test file. BUILD
    # halves collect into ``test-builds`` (compile verification); EXECUTE
    # halves collect into ``test`` so ``repro test`` / ``repro build test``
    # materialise the runnable closure.
    #
    # ``paths = @["src", "tests"]`` supplies ``--path:src --path:tests``
    # (isonim-tui-serve has no ``config.nims``; the ``Justfile`` bakes both
    # in). ``src`` is an ``extraInput`` so the whole module tree is a
    # declared input of every compile.
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    # Capacity-1 pool serialising the subprocess/socket bridge test.
    let serialPool = buildPool(bridgePool, 1'u32)
    discard serialPool

    proc emitTestPair(source, binary, pool: string;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        defines = @["release"],
        paths = @["src", "tests"],
        mm = "orc",
        extraInputs = @["src"],
        actionId = "isonim_tui_serve.test_build." & stem)
      buildActions.add(edge.action)
      # ``registerImplicitName = false`` because the BUILD edge already owns
      # the binary basename as the implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (two-edge shape).
      let executeEdge =
        if pool.len > 0:
          edge.testBinary.run(
            actionId = "isonim_tui_serve.test_execute." & stem,
            pool = pool,
            registerImplicitName = false)
        else:
          edge.testBinary.run(
            actionId = "isonim_tui_serve.test_execute." & stem,
            registerImplicitName = false)
      executeActions.add(executeEdge)

    for spec in serveTestSpecs:
      emitTestPair(spec.source, spec.binary, spec.pool,
        testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
