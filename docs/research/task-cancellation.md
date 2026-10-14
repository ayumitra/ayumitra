# Interrupting AI work

The companion exposes Stop during chat planning/composition, extended research,
explicit draft generation, and report extraction/notes. Settings and file routes
retain the same task bar above the Navigator. Destructive profile deletion and
credential persistence are not cancellable operations.

## Task ownership

`AppController._work` owns busy state, a cancellation token, affected report
ownership pairs, and a background-processing lease. The token travels through a
Dart Zone so a late continuation keeps the old task's identity after a new task
starts. `taskCall` checks before invoking an operation, races its future against
Stop, and checks again afterward. Contextual model calls use this boundary for
all local, host, and cloud roles. Research and parser catch blocks rethrow
`TaskCancelled`; it is not an invalid model answer and must not enter a format
repair, fallback, tool call or assistant-turn append.

Stop increments a synchronous revision once. Draft UI uses that revision along
with profile/session/source and edit revisions to reject stale output. Draft
opening performs no generation; the user chooses Generate. Leaving a generating
draft stops it synchronously without notifying during Flutter's locked unmount
phase; asynchronous task cleanup notifies surviving routes.

`busy` remains owned until cleanup completes. Never race an entire persistence
transaction and release busy while it can still overwrite newer state. A vault
write authorized before Stop must finish and be mirrored into controller data
before the next task can save. An import saves the original and its index/job as
one protected sequence, then honors Stop. Original files, user messages and
completed extraction are retained. Saving a submitted user message and its first
conversation is also a protected sequence; Stop cancels the answer rather than
losing that submitted intent.

## Runtime cancellation

- Native `.litertlm`: stop the active `InferenceModelSession` outside the
  generation serialization lock. An epoch rejects queued old requests and
  partial responses. Only the generation owner closes a session, after decoding
  and any concurrent stop have settled.
- Localhost bridge: each operation gets its own abort trigger and response
  subscription. Stop cancels that operation, without closing the reusable client,
  clearing valid model verification, or issuing a server-wide unload.
- Optional direct cloud: each request uses `http.AbortableRequest`; Stop signals
  abort and discards late output. An already submitted request cannot be unsent;
  interruption does not retract provider processing or change retention policy.

Unit tests verify native session calls/lifecycle with fake runtime sessions and
HTTP abort/subscription behavior with fake transports. These do not measure
physical-device accelerator stop latency; that needs a real-device check.

## Durable paused reports

`ReportProcessingJob.paused` defaults to false for older vaults. Stop marks the
affected report jobs paused without adding another attempt; automatic startup
enqueue preserves the flag, and the due-job selector skips it. Stopping a running
background batch also pauses its remaining queued reports. Explicit Retry clears
the pause and resets the attempt budget. Existing notes cannot make a failed new
summary attempt count as successful.

If saving the paused status fails, keep the jobs paused in memory, release work
protection and report the storage problem. Durability across restart is not
claimed when the save failed. Do not turn a user's Stop into an automatic retry.

Regression coverage lives in `task_cancellation_test.dart`,
`native_generation_cancellation_test.dart`, `transport_cancellation_test.dart`,
`background_processing_controller_test.dart`, `processing_jobs_test.dart`,
`agentic_draft_ui_test.dart`, and `settings_access_test.dart`.
