# Helmsman.jl (Helm.jl)

## Project Overview

Helmsman.jl (internal module name `Helm`) is an automated scheduler for the `Ark.jl` Entity Component System (ECS) framework. It analyzes system dependencies (component reads/writes and resource access) to build a dependency graph, enabling parallel execution of mutually exclusive systems.

### Key Technologies

- **Julia**: Core language.
- **Ark.jl**: The ECS framework this scheduler is built for.
- **Graphs.jl**: Used for dependency graph analysis and topological sorting.
- **MacroTools.jl**: Powering the `@system` macro for DSL-like system definitions.

### Architecture

- **Systems**: Captures requirements (Queries, Resources, Command Buffers) and the effects of world.
- **Scheduling**: `Schedule` objects are constructed from systems, chains, and explicit dependencies.
- **Automatic Parallelism**: The scheduler automatically detects data conflicts between systems (overlapping read/write sets) and enforces sequential execution only when necessary.
- **Dependency Analysis**: Uses a directed acyclic graph (DAG) and Kahn's algorithm to group independent systems into parallel **execution stages**.

---

## Building and Running

...

### Running Tests

Execute the test suite using the standard Julia test command:

```bash
julia --project=. test/run_tests.jl
```

Or from within the Julia REPL:

```julia
using Pkg; Pkg.test()
```

*Note: Parallel scheduling is verified in `test/schedule_parallel.jl`.*

---

## Development Conventions

### Code Structure

- `src/Helm.jl`: Main module entry point (exports core types and `@system`).
- `src/systems.jl`: Base types and access metadata extraction (`reads`, `writes`).
- `src/schedule.jl`: Logic for building schedules, conflict detection, and layered topological sorting.

### Coding Style

- Follows standard Julia package conventions.
- Uses `_` prefix for internal/private fields in structs (e.g., `_systems`).
- Leverages multiple dispatch for handling different system types (`System`, `SystemChain`, `SystemDependency`).

### Testing

- Tests are located in the `test/` directory.
- `run_tests.jl` is the main entry point.
- Uses the standard `Test` library.
- Ensure any new features in the `@system` macro are verified in `test/system_macro.jl`.
