/**
 * Pending tool call approval callbacks.
 * Used to coordinate between +layout.svelte (RPC handler) and
 * ToolCallDisplay.svelte (UI buttons).
 */
const pendingApprovals = new Map<string, (response: { approved: boolean }) => void>();

/**
 * Tool names that have been allowed-always for this chat session.
 * When a tool is in this set, future approval requests are auto-approved.
 */
const sessionAllowedTools = new Set<string>();

export function isToolAllowedAlways(name: string): boolean {
	return sessionAllowedTools.has(name);
}

export function setToolAllowedAlways(name: string): void {
	sessionAllowedTools.add(name);
}

export function registerApproval(
	id: string,
	name: string,
	args: Record<string, unknown>,
	cb: (response: { approved: boolean }) => void
) {
	if (sessionAllowedTools.has(name)) {
		cb({ approved: true });
		return;
	}
	pendingApprovals.set(id, cb);
}

export function getApprovalCallback(id: string) {
	return pendingApprovals.get(id);
}

export function clearApproval(id: string) {
	pendingApprovals.delete(id);
}
