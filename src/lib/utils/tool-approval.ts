/**
 * Pending tool call approval callbacks.
 * Used to coordinate between +layout.svelte (RPC handler) and
 * ToolCallDisplay.svelte (UI buttons).
 */
const pendingApprovals = new Map<string, (response: { approved: boolean }) => void>();

export function registerApproval(
	id: string,
	name: string,
	args: Record<string, unknown>,
	cb: (response: { approved: boolean }) => void
) {
	pendingApprovals.set(id, cb);
}

export function getApprovalCallback(id: string) {
	return pendingApprovals.get(id);
}

export function clearApproval(id: string) {
	pendingApprovals.delete(id);
}
