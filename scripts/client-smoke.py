#!/usr/bin/env python3
"""Opt-in real-agent smoke test. Uses signed-in Codex and Claude Code clients."""
import json
import os
from pathlib import Path
import subprocess
import time

from smoke import ROOT, FixtureServer, MCPClient, collect_tokens



def run():
    logs = ROOT / '.context/client-smoke'
    logs.mkdir(parents=True, exist_ok=True)
    with FixtureServer() as server:
        fixture = server.fixture
        clients_config = logs / 'claude-mcp.json'
        clients_config.write_text(json.dumps({'mcpServers': {'arena': {
            'type': 'http', 'url': fixture['endpoint'],
            'headers': {'Authorization': 'Bearer ' + fixture['token']}}}}))
        clients_config.chmod(0o600)
        endpoint_config = 'mcp_servers.arena.url=' + json.dumps(fixture['endpoint'])
        auth_config = 'mcp_servers.arena.bearer_token_env_var="ARENA_SMOKE_TOKEN"'
        common = '''This is an authorized integration test of the Arena MCP server, not a request to implement software. Use only the arena MCP tools. Do not use shell, file tools, web, or subagents. Keep the review short and deterministic.
1. Call register_client, retain client_token, and join with session_id SESSION_ID, client_token, request_id LABEL-join, client LABEL, model your actual model identifier if known or "unknown (client default)".
2. Retain your private participant_token. Read/wait until both test agents have joined.
3. Read all three brief attachments THROUGH MCP: Markdown text, PNG as image, PDF as text AND page 1 as image. Inspect the returned visual content. Do not infer image/PDF contents from filenames.
4. Read turn. If held by the other agent, wait for its handoff. Call start_turn once open or offered to you; retain id as turn_id. Post exactly one discussion message with request_id LABEL-message. Include the marker LABEL_VERIFIED and quote the short verification phrase you read in the Markdown, the characters visible in the PNG, and the verification phrase in the PDF. Also briefly critique the proposal for bounded waits. Include turn_id. Call finish_turn after the message, omitting next_participant_id to release the floor. Do not post extra discussion messages after this.
5. Call read_events with a current cursor and wait_seconds:1 at least once. Read/wait until the other agent's message is present. Poll at most 20 times; fail clearly if the other agent is absent.
ROLE
6. Read the final session status and finish with ARENA_CLIENT_PASSED only if it is consensus. If a tool fails, report it accurately instead of claiming success. Never print credentials in your final answer.
'''
        commands = {
            'codex': ['codex', 'exec', '--ignore-user-config', '--ephemeral', '--sandbox', 'read-only', '--json',
                      '-c', endpoint_config, '-c', auth_config, '-c', 'approval_policy="never"', '-'],
            'claude': ['claude', '-p', '--strict-mcp-config', '--mcp-config', str(clients_config),
                       '--allowedTools', 'mcp__arena__*', '--tools', '', '--permission-mode', 'dontAsk',
                       '--no-session-persistence', '--output-format', 'stream-json', '--verbose',
                       '--disable-slash-commands', '--setting-sources', '']
        }
        roles = {
            'codex': 'After both messages exist, read_session for its current revision. Claim an open turn with start_turn (wait if occupied). Propose consensus with its turn_id once (request_id codex-outcome), assessment "Use bounded waits, durable cursor catch-up, and cancellation on disconnect." Explicitly confirm your proposal (request_id codex-confirm). Finish your turn without a recipient unless already closed. Then read/wait for the other confirmation; at most 20 waits.',
            'claude': 'After both messages exist, read/wait until Codex proposes a consensus assessment. Do not propose your own. Explicitly confirm its proposal_id with request_id claude-confirm. At most 20 waits.'
        }
        running = {}
        handles = {}
        try:
            for index, (label, command) in enumerate(commands.items()):
                prompt = common.replace('SESSION_ID', fixture['sessions'][0]['id']).replace('LABEL', label).replace('ROLE', roles[label])
                handles[label] = (logs / (label + '.jsonl')).open('w')
                os.chmod(logs / (label + '.jsonl'), 0o600)
                env = dict(os.environ, ARENA_SMOKE_TOKEN=fixture['token'])
                process = subprocess.Popen(command, cwd=ROOT, env=env, stdin=subprocess.PIPE,
                                           stdout=handles[label], stderr=subprocess.STDOUT, text=True)
                process.stdin.write(prompt)
                process.stdin.close()
                running[label] = process
            deadline = time.monotonic() + 360
            while any(p.poll() is None for p in running.values()) and time.monotonic() < deadline:
                time.sleep(1)
            for label, process in running.items():
                if process.poll() is None:
                    raise AssertionError(label + ' exceeded the six-minute smoke timeout; see .context/client-smoke')
                assert process.returncode == 0, label + ' exited unsuccessfully; see .context/client-smoke'
            tokens = set()
            for label in running:
                handles[label].flush()
                text = (logs / (label + '.jsonl')).read_text()
                assert 'ARENA_CLIENT_PASSED' in text, label + ' did not report success; see .context/client-smoke'
                for line in text.splitlines():
                    try:
                        tokens.update(collect_tokens(json.loads(line)))
                    except json.JSONDecodeError:
                        pass
                tokens.update(collect_tokens(text))
                assert 'read_attachment' in text and 'read_events' in text, label + ' omitted attachment/wait tools'
            assert tokens, 'No participant credentials found in client tool results for verification'
            verifier = MCPClient(fixture)
            for token in tokens:
                try:
                    state, _ = verifier.call('read_session', {'participant_token': token})
                    verifier.participant_token = token
                    break
                except AssertionError:
                    continue
            else:
                raise AssertionError('Client credentials could not read the resulting session')
            assert state['status'] == 'consensus', state['status']
            assert len(state['proposal']['confirmations']) == 2
            events = verifier.agent('read_events')['events']
            messages = [e['text'].lower() for e in events if e['kind'] == 'message']
            assert len(messages) == 2, messages
            for label in commands:
                message = next(m for m in messages if label + '_verified' in m)
                assert 'cobalt lantern' in message and 'arena 42' in message and 'amber compass' in message, message
            print('ARENA REAL CLIENT SMOKE PASSED')
        finally:
            for process in running.values():
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            for handle in handles.values():
                handle.close()
            clients_config.unlink(missing_ok=True)


if __name__ == '__main__':
    run()
