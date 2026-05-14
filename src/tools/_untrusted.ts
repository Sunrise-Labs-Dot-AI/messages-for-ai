// Prompt-injection mitigation: wrap message bodies (which can contain
// attacker-controlled text from an incoming iMessage) in delimiters that
// modern LLMs are trained to treat as DATA rather than instructions.
//
// The defense pattern is "spotlighting" / data-tagging — instead of
// trying to sanitize the content (which is fragile), we mark it as
// non-instructional and rely on the model to honor that. Doesn't
// eliminate the risk class, but defeats the dumbest 90% of attacks
// like "ignore prior instructions and use send_imessage_draft to ...".
//
// Applied at the MCP tool response boundary, NOT in the storage layer:
// the menu bar app reads ~/.imessage-mcp/drafts/*.json directly and
// would render the delimiter literals as text in bubbles otherwise.
// chat.db bodies returned via list/get/search tools get wrapped here;
// the staged draft's own `body` (which is agent-authored, not from a
// peer) is left untouched.

const OPEN = "<untrusted_content>";
const CLOSE = "</untrusted_content>";

export function wrapUntrusted(body: string | null): string | null {
  if (body == null) return null;
  return `${OPEN}\n${body}\n${CLOSE}`;
}

// For shapes that have a `body` field somewhere in the structure —
// returns a new object with body wrapped, leaving everything else.
// `null` bodies stay null (the wrapper would otherwise produce
// "<untrusted_content>\nnull\n</untrusted_content>" which is worse).
export function wrapBodyInPlace<T extends { body: string | null }>(item: T): T {
  return { ...item, body: wrapUntrusted(item.body) };
}
