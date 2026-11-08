# GameServer Engine (GSE) Workspace Reference

Parent Operating Instructions Version: 1.0.0

This file is the authoritative source of truth for the GameServer Engine (GSE) ecosystem in this workspace.

Location: `/home/dev/Projects/GSP/AGENTS.md`

The local workspace folder is still named `GSP` for historical compatibility. Treat `GSP` in directory names, repository names, service names, protocol identifiers, database prefixes, scripts, package paths, and runtime paths as a legacy compatibility identifier unless a task explicitly includes a coordinated migration.

GSE is a multi-repository system. Treat the repositories below as one product with separate source control boundaries:

- `Panel` - GameServer Engine management console, control plane, shared documentation, admin tooling, and user-facing web modules
- `GSP-Agent-Linux` - Linux execution engine and OGP-compatible Perl agent
- `GSP-Agent-Windows` - Windows/Cygwin execution engine and OGP-compatible Perl agent

## Repository routing

- Workspace root: `/home/dev/Projects/GSP` (multi-repository container; not itself a Git repository).
- Panel/control-plane repository: `/home/dev/Projects/GSP/Panel`.
- Gameservers.World storefront: `/home/dev/Projects/GSP/Panel/modules/billing`.
- Linux agent repository: `/home/dev/Projects/GSP/GSP-Agent-Linux`.
- Windows agent repository: `/home/dev/Projects/GSP/GSP-Agent-Windows`.

Storefront-only work must run Codex with `/home/dev/Projects/GSP/Panel` as the Git working tree and must edit `modules/billing` within that repository.

Panel management-console work belongs in `/home/dev/Projects/GSP/Panel` outside `modules/billing` as appropriate.

Workspace-level cross-repository investigations may start from `/home/dev/Projects/GSP`, but Git operations must occur inside the affected repository or repositories.

When a change touches architecture, communication, lifecycle behavior, status reporting, Workshop/content delivery, installers, or updates, review all three repositories before changing code.

## Canonical responsibilities

# Reference Material

The references directory is read-only.

references/
└── OGP/

The OGP codebase is the original upstream project and exists solely as reference material.

Rules:

- Never modify files under references/.
- Never commit changes under references/.
- Never move, rename, or delete files under references/.
- Use OGP only to understand original behavior.
- If functionality is missing or broken in GSE, compare against OGP and implement fixes in GSE code only.
- All development work must occur outside references/.


| Repository | Ownership | Primary runtime role | Important notes |
| --- | --- | --- | --- |
| `Panel` | GameServer Engine management console, shared docs, admin tools, and Gameservers.World storefront module | Control plane | The Panel is authoritative for user actions and business logic. Gameservers.World lives under `modules/billing`; it is not a separate top-level repository and is not the whole Panel. |
| `GSP-Agent-Linux` | Linux agent and Linux runtime layer | Execution engine | Uses Linux-native process management and aligns with panel RPC expectations. |
| `GSP-Agent-Windows` | Windows agent and Cygwin runtime layer | Execution engine | Uses Cygwin to mirror Linux behavior as closely as practical. |

## Architecture model

The platform is designed as a control plane plus execution engines:

User
→ Panel module
→ Panel command generation
→ Panel communication layer
→ Linux or Windows agent
→ OGP Perl agent
→ operating system
→ game server process

The Panel decides what should happen. The agents execute requests and report results. Agents should not make business decisions that belong in the Panel.

## Command and status flow

The common runtime path is:

1. A user performs an action in the Panel.
2. A Panel module builds a request.
3. The Panel sends the request through its remote communication layer.
4. The Linux or Windows agent receives the request.
5. The OGP Perl agent executes the command or lifecycle action.
6. The agent returns status, logs, or command results.
7. The Panel updates the UI and database state.

Typical actions include:

- start, stop, restart, and monitor servers
- retrieve logs
- manage files and configs
- install mods and Workshop content
- schedule safe automation tasks
- update application code

## Update safety rules

Repository updates must preserve customer data. Never overwrite or delete:

- user home folders
- game server data
- save files
- configuration files
- Workshop content
- custom scripts
- user-created files
- logs unless a documented rotation policy says otherwise

Application updates should only replace code and bundled runtime files that are explicitly part of the software package.

## Documentation entry points

Use these as the first files to read in each repository:

### Panel

- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/PANEL_ARCHITECTURE.md`
- `docs/AGENT_COMMUNICATION.md`
- `docs/REPOSITORY_STRUCTURE.md`
- `docs/COMMAND_FLOW.md`
- `docs/UPDATE_POLICY.md`

### GSP-Agent-Linux

- `README.md`
- `docs/AGENT_ARCHITECTURE.md`
- `docs/COMMAND_EXECUTION.md`
- `docs/PROCESS_MANAGEMENT.md`
- `docs/PANEL_INTEGRATION.md`

### GSP-Agent-Windows

- `README.md`
- `docs/AGENT_ARCHITECTURE.md`
- `docs/CYGWIN_INTEGRATION.md`
- `docs/COMMAND_EXECUTION.md`
- `docs/PROCESS_MANAGEMENT.md`
- `docs/PANEL_INTEGRATION.md`

## Development rule

If a change affects protocol shape, lifecycle behavior, configuration format, update flow, or runtime assumptions, update the relevant documentation in all affected repositories before considering the work complete.

===============================================================================
CODEX ENGINEERING HISTORY POLICY
===============================================================================

Every Codex task MUST create a permanent engineering history record.

Create:

docs/codex-history/YYYY/

Filename:

YYYY-MM-DD-HHMM-short-task-name.md

Every history record must contain:

# Task

## User Request

(original request)

## Problem

## Root Cause

## Repositories Inspected

## Files Read

## Files Changed

## Architecture Decisions

## Validation Performed

## Git Commits

Repository

Commit

Hash

## Remaining Work

Never overwrite history.

Always create a new record.

These records become part of the permanent engineering documentation.

===============================================================================
AUTOMATIC GIT POLICY
===============================================================================

After successful validation:

Every repository changed MUST receive a focused git commit.

Rules:

Run git status before staging.

Stage only task-related files.

Do not stage unrelated work.

If validation fails:

DO NOT COMMIT.

Leave work uncommitted.

Explain why.

Commit messages must describe completed work.

Never use:

Update

Changes

Misc

Fixes

Examples:

Improve Windows lifecycle parity

Fix Panel restart synchronization

Move sidecars into server-content lifecycle

Improve server_status reliability

Document production workflow

For multi-repository work:

Commit separately in every repository.

===============================================================================
FINAL REPORT POLICY
===============================================================================

Every task must finish with:

Summary of request

Root cause

Repositories inspected

Files read

Files changed

Architecture decisions

Validation results

History record path

Git commits

Remaining work

## Global ISA infrastructure
Before infrastructure-related work, read `/home/dev/Projects/ISA-KNOWLEDGE/INFRASTRUCTURE.md`. This is the canonical shared non-secret host/IP/VPN/account/service source of truth.

## Coding Standards

- Fix the root cause. Do not put a patch on top of broken code.
  If a rule or function is wrong, change that rule or function.
- CSS: change the rule where it is first written. Do not add a second
  rule that overrides it.
- Write the simplest code that works. Use plain steps that a beginner can follow.
- Use a harder method only when it is really needed. Say why in a comment.
- Do not write short clever code just to save lines. Clear code is better.
- Keep each function to one job, and keep functions short.
- Before you finish, read your change once as if you are new to the project.
  If it is hard to follow, make it simpler.
- Never put tokens, passwords, or keys in code, docs, or git history.

## Work Tracking

Every repo keeps its open work in `docs/TODO.md`.

- Read `docs/TODO.md` before you start work in this repo.
- Update it every time you work in this repo. Add anything you find, even if you found it by accident.
- Use these types:
  - `todo`: work that must be done.
  - `issue`: a bug or problem.
  - `goal`: something the user wants later.
  - `need`: something you can see will be needed in the future.
- Keep one row per item. Do not delete rows.
- When work is done, set Status to `done`. Write who did it in Owner.
- Set Status to `invalid` only when the item is wrong or no longer needed. Leroy deletes the matching GitLab item during sync.
- Owner is who did or will do the work: `Claude`, `Codex`, `Leroy`, or the user's name.
- Commit the `docs/TODO.md` change together with the code change.
- The user and Leroy review this file. Then Leroy creates or updates the matching GitLab issue or work item and writes its link in the GitLab column.
