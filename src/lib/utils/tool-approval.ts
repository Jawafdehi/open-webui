/**
 * Pending tool call approval callbacks.
 * Used to coordinate between +layout.svelte (RPC handler) and
 * ToolCallDisplay.svelte (UI buttons).
 *
 * Supports two resolution paths:
 * 1. Normal: RPC callback registered by the `approval:tool` event handler.
 * 2. Reconnect: socket emit via `respondToApproval` when no callback is
 *    registered (tab crash / reconnection scenario).
 */
import { socket } from '$lib/stores';
import type { Socket } from 'socket.io-client';

const pendingApprovals = new Map<string, (response: { approved: boolean }) => void>();

let socketInstance: Socket | null = null;
const unsubscribe = socket.subscribe((s) => {
	socketInstance = s;
});

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

/**
 * Send an approval decision to the backend via the WebSocket.
 * Used when the RPC callback is unavailable (e.g. after reconnection).
 */
export function respondToApproval(id: string, approved: boolean) {
	if (socketInstance) {
		socketInstance.emit('approval:tool:response', { id, approved });
	}
}

/**
 * Request the backend to re-present a pending approval to this client.
 * Called by ToolCallDisplay on mount when it detects an awaiting-approval
 * tool call with no registered callback (reconnection scenario).
 */
export function requestRestore(id: string) {
	if (socketInstance && socketInstance.connected) {
		socketInstance.emit('approval:tool:restore', { id });
	}
}
