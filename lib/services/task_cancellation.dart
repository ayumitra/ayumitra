import 'dart:async';

/// A stopped task is an expected outcome, never a model error or repair signal.
class TaskCancelled implements Exception {
  const TaskCancelled();
  @override
  String toString() => 'Task cancelled.';
}

class CancellationToken {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const TaskCancelled();
  }

  /// Attaches both result/error handlers even when already cancelled. A late
  /// underlying failure is consumed; cancellation cannot create unhandled errors.
  Future<T> race<T>(Future<T> operation) {
    final result = Completer<T>();
    operation.then<void>(
      (value) {
        if (!result.isCompleted) {
          if (isCancelled) {
            result.completeError(const TaskCancelled());
          } else {
            result.complete(value);
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) {
          result.completeError(
            isCancelled ? const TaskCancelled() : error,
            stack,
          );
        }
      },
    );
    whenCancelled.then<void>((_) {
      if (!result.isCompleted) result.completeError(const TaskCancelled());
    });
    return result.future;
  }
}
