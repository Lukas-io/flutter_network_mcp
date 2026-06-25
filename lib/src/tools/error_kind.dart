/// Stable, agent-branchable classification of a tool failure.
///
/// Every error response carries an `errorKind` field set from one of these.
/// The agent switches on the wire string to choose a recovery path instead of
/// parsing free-text error messages (which drift and are unreliable to match).
///
/// **Wire strings are a contract: never rename a value's [wire].** Adding new
/// kinds is safe; an agent that sees an unknown kind treats it as [internal].
enum ErrorKind {
  /// The agent passed a missing or invalid argument. Recovery: fix the call.
  badArgument('bad_argument'),

  /// The referenced id / session / request does not exist. Recovery: re-list.
  notFound('not_found'),

  /// No attached session, or the scope could not be resolved. Recovery:
  /// network_attach / session_open / pass an explicit sessionId.
  noSession('no_session'),

  /// A VM service RPC timed out or the connection is unusable (app paused,
  /// backgrounded, DDS wedged). Recovery: retry, or read from the DB instead.
  unresponsiveVm('unresponsive_vm'),

  /// A malformed SQL or search expression. The response carries the schema /
  /// available terms so the agent can self-correct on the next call.
  badQuery('bad_query'),

  /// The capability backing this tool is disabled. Recovery: enable it / use
  /// another tool.
  capabilityDisabled('capability_disabled'),

  /// An unexpected failure with no more specific classification.
  internal('internal');

  const ErrorKind(this.wire);

  /// Stable wire string emitted as `errorKind`. Never rename.
  final String wire;
}
