#!/usr/bin/env python3
"""Exercise the shipped skill with two signed-in clients against disposable Arena data."""
import json
import os
import subprocess
import time

from smoke import ROOT, FixtureServer, MCPClient, collect_tokens


def run():
    skill = (ROOT / 'Sources/Arena/Resources/arena/SKILL.md').read_text()
    logs = ROOT / '.context/skill-smoke'
    logs.mkdir(exist_ok=True)
    with FixtureServer() as server:
        fixture = server.fixture
        config = logs / 'mcp.json'
        config.write_text(json.dumps({'mcpServers': {'arena': {'type': 'http', 'url': fixture['endpoint'],
                           'headers': {'Authorization': 'Bearer ' + fixture['token']}}}}))
        config.chmod(0o600)
        commands = {
            'codex': ['codex', 'exec', '--ignore-user-config', '--ephemeral', '--sandbox', 'read-only', '--json',
                      '-c', 'mcp_servers.arena.url=' + json.dumps(fixture['endpoint']),
                      '-c', 'mcp_servers.arena.bearer_token_env_var="ARENA_SMOKE_TOKEN"',
                      '-c', 'approval_policy="never"', '-'],
            'claude': ['claude', '-p', '--strict-mcp-config', '--mcp-config', str(config),
                       '--allowedTools', 'mcp__arena__*', '--tools', '', '--permission-mode', 'dontAsk',
                       '--no-session-persistence', '--output-format', 'stream-json', '--verbose',
                       '--disable-slash-commands', '--setting-sources', '']
        }
        common = '''Use the Arena skill below for this authorized integration test. Use only Arena MCP tools; no shell, file, web, or subagent tools. Another independent client participates. This is review-only; neither client is the implementing agent, so no temporary implementation notes are needed in this fixture. Keep the review short: each participant should contribute two substantive discussion messages, including a reply to the other participant, then pursue a unanimous assessment if warranted. Wait for actual closure; do not manufacture the other participant's confirmation. Finish with ARENA_SKILL_PASSED only after reading a closed consensus or impasse. Keep credentials out of your final answer.

'''
        prompts = {
            'codex': 'I approve creating a session named "Skill review smoke" for an open discussion. Use this initial proposal as the brief: "Use read_events with a 25-second wait and cursor catch-up. If one wait returns no new events, automatically declare consensus." You are the initiating agent. Create and join the session, put forward the proposal, and discuss it with the challenger.',
            'claude': 'Find and join the existing session named "Skill review smoke" as its second agent. Begin an independent adversarial review of the initial proposal and discuss your findings with the initiating agent.'
        }
        running, handles = {}, {}
        try:
            observer = MCPClient(fixture)
            for label, command in commands.items():
                handles[label] = (logs / (label + '.jsonl')).open('w')
                os.chmod(logs / (label + '.jsonl'), 0o600)
                process = subprocess.Popen(command, cwd=ROOT, env=dict(os.environ, ARENA_SMOKE_TOKEN=fixture['token']),
                                           stdin=subprocess.PIPE, stdout=handles[label], stderr=subprocess.STDOUT, text=True)
                process.stdin.write(common + prompts[label] + '\n\n' + skill)
                process.stdin.close()
                running[label] = process
                if label == 'codex':
                    deadline = time.monotonic() + 90
                    while time.monotonic() < deadline:
                        page, _ = observer.call('list_sessions', {'query': 'Skill review smoke'})
                        if page['sessions'] and page['sessions'][0]['joined_count'] == 1:
                            session_id = page['sessions'][0]['id']
                            break
                        if process.poll() is not None:
                            raise AssertionError('Initiator ended before creating and joining; inspect private logs')
                        time.sleep(.5)
                    else:
                        raise AssertionError('Initiator did not create and join within 90 seconds')
            deadline = time.monotonic() + 300
            while any(p.poll() is None for p in running.values()) and time.monotonic() < deadline:
                time.sleep(1)
            tokens = set()
            for label, process in running.items():
                assert process.poll() == 0, label + ' failed or exceeded five minutes; inspect private logs'
                handles[label].flush()
                output = (logs / (label + '.jsonl')).read_text()
                assert 'ARENA_SKILL_PASSED' in output, label + ' did not finish the skill'
                for line in output.splitlines():
                    try:
                        tokens.update(collect_tokens(json.loads(line)))
                    except json.JSONDecodeError:
                        pass
                tokens.update(collect_tokens(output))
            page, _ = observer.call('list_sessions', {'query': session_id})
            assert len(page['sessions']) == 1
            assert page['sessions'][0]['status'] in ('consensus', 'impasse')
            assert page['sessions'][0]['joined_count'] == 2
            for token in tokens:
                try:
                    state, _ = observer.call('read_session', {'participant_token': token})
                    if state['id'] == session_id:
                        observer.participant_token = token
                        break
                except AssertionError:
                    continue
            else:
                raise AssertionError('No participant credential found for history verification')
            assert len(state['proposal']['confirmations']) == 2
            assert state['turn'] is None
            events = observer.agent('read_events')['events']
            messages = [event for event in events if event['kind'] == 'message']
            for participant in state['participants']:
                contributions = [event for event in messages if event['participantID'] == participant['id']]
                assert len(contributions) >= 2, 'Each agent must contribute and reply'
            assert any(event.get('replyTo') for event in messages), 'No reply references in the discussion'
            assert any(event.get('messageType') == 'rebuttal' for event in messages), 'No explicit rebuttal in the adversarial pass'
            assert any(event['kind'] == 'turn_started' for event in events), 'No thinking signal'
            assert any(event['kind'] == 'turn_passed' for event in events), 'No explicit peer handoff'
            first_proposal = next(i for i, event in enumerate(events) if event['kind'] == 'proposed')
            discussed = {event['participantID'] for event in events[:first_proposal] if event['kind'] == 'message'}
            assert len(discussed) >= 2, 'A proposal was made before discussion with a peer'
            print('ARENA REAL SKILL SMOKE PASSED')
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
            config.unlink(missing_ok=True)


if __name__ == '__main__':
    run()
