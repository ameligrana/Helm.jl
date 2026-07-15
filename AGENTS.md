# Repository Guidelines

## Project Structure & Module Organization

Helm.jl is a Julia package for scheduling Ark.jl systems. The package entry point is `src/Helm.jl`, which exports the public API and includes implementation files. Core scheduling logic lives in `src/schedule.jl`, `src/scheduler.jl`, and `src/systems.jl`. System configuration helpers are grouped under `src/SystemConfigs/`. Tests live in `test/`, with `test/run_tests.jl` acting as the current test runner and `test/schedule_parallel.jl` covering scheduling behavior.

## Build, Test, and Development Commands

- `julia --project=. -e 'using Pkg; Pkg.instantiate()'`: install package dependencies from `Project.toml` and `Manifest.toml`.
- `julia --project=. -e 'using Helm'`: quick load check for the package.
- `julia --project=. test/run_tests.jl`: run the repository test entry point.
- `julia --project=.`: start a REPL with the local environment active for interactive development.

There is no separate build step; Julia compiles methods as needed.

## Coding Style & Naming Conventions

Use idiomatic Julia with four-space indentation in new code. Keep module exports centralized in `src/Helm.jl`. Prefer explicit method definitions over large conditional blocks, and keep type parameters constrained where they document intent, as in `Schedule{N,T}` and `System{T,C}`. Use `CamelCase` for types and constructors, `snake_case` for functions and local variables, and lowercase filenames that match their domain, such as `schedule.jl`.

## Testing Guidelines

Use Julia's standard `Test` framework and group related assertions with `@testset`. Place new tests under `test/` and include them from `test/run_tests.jl`. Name test files after the behavior under test, for example `schedule_parallel.jl`. Add tests for dependency ordering, read/write conflict detection, and public API behavior when changing scheduler logic.

## Commit & Pull Request Guidelines

Recent commits use short, imperative or past-tense summaries, for example `added command buffer scaffold` and `renamed module file`. Keep commit subjects concise and focused on one change. Pull requests should describe the behavioral change, list the test command run, and link relevant issues. Include examples or screenshots only when changing user-facing documentation or visual output.

## Agent-Specific Instructions

Do not overwrite local work. Check `git status --short` before editing, keep changes narrowly scoped, and avoid modifying generated or unrelated files unless the task requires it.
