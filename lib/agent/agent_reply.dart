/// What the on-device agent produces for a turn: plain (markdown) text and/or a
/// rich flex card — mirrors the server Reply contract so the same FlexCardView
/// renders it.
class AgentReply {
  final String? text;
  final Map<String, dynamic>? flex;
  final List<String> usedTools; // tool names the agent called this turn
  final List<String> trace; // debug-bot: step-by-step tool calls + results
  const AgentReply(
      {this.text,
      this.flex,
      this.usedTools = const [],
      this.trace = const []});

  bool get isEmpty => (text == null || text!.isEmpty) && flex == null;

  AgentReply withTools(List<String> tools) =>
      AgentReply(text: text, flex: flex, usedTools: tools, trace: trace);
}

/// A tool's outcome: either `feedback` text fed back to the model to continue
/// the loop (e.g. web_search results the model then phrases), or a `reply` that
/// ends the turn and is shown as-is (e.g. a weather card / rendered HTML).
class ToolResult {
  final String? feedback;
  final AgentReply? reply;
  const ToolResult.feedback(this.feedback) : reply = null;
  const ToolResult.terminal(this.reply) : feedback = null;
}
