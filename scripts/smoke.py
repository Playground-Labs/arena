#!/usr/bin/env python3
"""Real localhost MCP integration; creates only disposable fixture data."""
import base64
import concurrent.futures
import json
import os
import re
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def collect_tokens(value):
    found = set()
    if isinstance(value, dict):
        token = value.get('participant_token')
        if isinstance(token, str):
            found.add(token)
        for child in value.values():
            found.update(collect_tokens(child))
    elif isinstance(value, list):
        for child in value:
            found.update(collect_tokens(child))
    elif isinstance(value, str):
        try:
            decoded = json.loads(value)
            if decoded != value:
                found.update(collect_tokens(decoded))
        except (ValueError, TypeError):
            text = value.replace('\\"', '"')
            found.update(re.findall(r'"participant_token"\s*:\s*"([A-Fa-f0-9-]+)"', text))
    return found


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class FixtureServer:
    def __enter__(self):
        (ROOT / '.context').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='arena-smoke-', dir=ROOT / '.context')
        self.folder = Path(self.temp.name)
        self.fixture_file = self.folder / 'fixture.json'
        self.log = (self.folder / 'server.log').open('w')
        self.port = free_port()
        binary = ROOT / '.build/debug/Arena'
        if not binary.exists():
            raise RuntimeError('Run swift build -j 4 before this smoke test.')
        env = dict(os.environ, ARENA_HEADLESS='1', ARENA_DATA_DIR=str(self.folder / 'data'),
                   ARENA_PORT=str(self.port), ARENA_FIXTURE_PATH=str(self.fixture_file))
        self.process = subprocess.Popen([str(binary)], cwd=ROOT, env=env, stdout=self.log, stderr=self.log)
        for _ in range(200):
            if self.process.poll() is not None:
                self.log.flush()
                raise RuntimeError((self.folder / 'server.log').read_text())
            if self.fixture_file.exists():
                self.fixture = json.loads(self.fixture_file.read_text())
                try:
                    with socket.create_connection(('127.0.0.1', self.port), timeout=.1):
                        return self
                except OSError:
                    pass
            time.sleep(.1)
        self.__exit__(None, None, None)
        raise RuntimeError('Arena did not start within 20 seconds.')

    def __exit__(self, *_):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()
        self.temp.cleanup()


class MCPClient:
    def __init__(self, fixture):
        self.endpoint = fixture['endpoint']
        self.token = fixture['token']
        self.session = None
        response = self.rpc('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                                          'clientInfo': {'name': 'arena-smoke', 'version': '1'}})
        assert response['result']['protocolVersion'], response
        self.rpc('notifications/initialized', {}, notification=True)

    def rpc(self, method, params, notification=False, request_id=7):
        message = {'jsonrpc': '2.0', 'method': method, 'params': params}
        if not notification:
            message['id'] = request_id
        headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream',
                   'Authorization': 'Bearer ' + self.token, 'MCP-Protocol-Version': '2025-11-25'}
        if self.session:
            headers['Mcp-Session-Id'] = self.session
        request = urllib.request.Request(self.endpoint, json.dumps(message).encode(), headers)
        with urllib.request.urlopen(request, timeout=35) as response:
            self.session = response.headers.get('Mcp-Session-Id', self.session)
            if notification:
                response.read()
                return None
            if 'text/event-stream' in response.headers.get('Content-Type', ''):
                event_data = []
                for raw in response:
                    line = raw.decode().rstrip('\r\n')
                    if line.startswith('data:'):
                        event_data.append(line[5:].lstrip(' '))
                    elif not line:
                        data = '\n'.join(event_data)
                        event_data = []
                        if data.strip():
                            payload = json.loads(data)
                            if payload.get('id') == request_id:
                                return payload
                raise AssertionError('SSE ended without the requested response')
            return json.load(response)

    def call(self, name, arguments, error=False):
        envelope = self.rpc('tools/call', {'name': name, 'arguments': arguments})
        if error:
            assert 'error' in envelope or envelope.get('result', {}).get('isError'), envelope
            return envelope
        assert 'error' not in envelope, envelope
        result = envelope['result']
        assert not result.get('isError'), result
        data = result.get('structuredContent')
        if data is None:
            data = json.loads(next(x['text'] for x in result['content'] if x['type'] == 'text'))
        return data, result.get('content', [])

    def join(self, invitation, label):
        data, _ = self.call('join_session', dict(invitation=invitation, request_id=label + '-join', client=label, model='smoke'))
        self.participant_token = data['participant_token']
        return data

    def agent(self, name, **arguments):
        return self.call(name, dict(participant_token=self.participant_token, **arguments))[0]


def run():
    with FixtureServer() as server:
        fixture = server.fixture
        first, second = MCPClient(fixture), MCPClient(fixture)
        created, _ = first.call('create_session', {'name': 'Skill bootstrap', 'brief': 'Review the bounded wait protocol.', 'agent_count': 2, 'request_id': 'create-through-http'})
        duplicate, _ = first.call('create_session', {'name': 'Skill bootstrap', 'brief': 'Review the bounded wait protocol.', 'agent_count': 2, 'request_id': 'create-through-http'})
        assert created == duplicate
        discovered, _ = second.call('list_sessions', {'query': created['session_id']})
        assert len(discovered['sessions']) == 1 and discovered['sessions'][0]['joined_count'] == 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            claims = [executor.submit(client.call, 'join_session', {'session_id': created['session_id'], 'request_id': label, 'client': label, 'model': 'test'}) for client, label in [(first, 'skill-first'), (second, 'skill-second')]]
            joined_slots = [claim.result()[0] for claim in claims]
        assert len({slot['participant_token'] for slot in joined_slots}) == 2
        assert any(slot['status'] == 'active' for slot in joined_slots)
        slots = fixture['sessions'][0]['invitations']
        first.join(slots[0], 'alpha')
        joined = second.join(slots[1], 'beta')
        assert joined['status'] == 'active'
        names = [p['name'] for p in joined['participants']]
        assert len(set(names)) == 2
        tools = first.rpc('tools/list', {})['result']['tools']
        assert len(tools) == 10, tools
        first.call('read_session', {'participant_token': 'invalid'}, error=True)
        try:
            urllib.request.urlopen(urllib.request.Request(fixture['endpoint'], b'{}', {'Content-Type': 'application/json'}))
            raise AssertionError('Unauthenticated request accepted')
        except urllib.error.HTTPError as error:
            assert error.code == 401, error.code
        for header in ({'Origin': 'https://attacker.example'}, {'Host': 'attacker.example'}):
            request = urllib.request.Request(fixture['endpoint'], b'{}', {'Content-Type': 'application/json',
                'Authorization': 'Bearer ' + fixture['token'], **header})
            try:
                urllib.request.urlopen(request)
                raise AssertionError('Untrusted origin/host accepted')
            except urllib.error.HTTPError as error:
                assert error.code in (400, 403), error.code
        before = first.agent('read_session')
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            pending = executor.submit(first.agent, 'read_events', after_cursor=before['latest_cursor'], wait_seconds=3)
            time.sleep(.15)
            message = second.agent('post_message', request_id='beta-message', text='Bounded waits prevent indefinite blocked calls.')
            event_batch = pending.result(timeout=5)
        assert event_batch['events'][-1]['id'] == message['id']
        assert second.agent('post_message', request_id='beta-message', text='Bounded waits prevent indefinite blocked calls.')['id'] == message['id']
        second.call('post_message', dict(participant_token=second.participant_token, request_id='beta-message', text='Changed input'), error=True)
        state = first.agent('read_session')
        start = time.monotonic()
        empty = first.agent('read_events', after_cursor=state['latest_cursor'], wait_seconds=1)
        assert not empty['events'] and .8 < time.monotonic() - start < 3
        attachment_ids = {a['name']: a['id'] for a in state['attachments']}
        text = first.agent('read_attachment', attachment_id=attachment_ids['proposal.md'], representation='text')
        assert 'cobalt lantern' in text['text']
        _, image = second.call('read_attachment', dict(participant_token=second.participant_token, attachment_id=attachment_ids['diagram.png'], representation='image'))
        assert any(x['type'] == 'image' and base64.b64decode(x['data']).startswith(b'\x89PNG') for x in image)
        pdf = first.agent('read_attachment', attachment_id=attachment_ids['review.pdf'], representation='text')
        assert 'Amber compass' in pdf['text'], pdf
        _, page = second.call('read_attachment', dict(participant_token=second.participant_token, attachment_id=attachment_ids['review.pdf'], representation='image', page=1))
        assert any(x['type'] == 'image' for x in page)
        upload = first.agent('attach_file', request_id='upload', path=fixture['files'][0])
        assert first.agent('attach_file', request_id='upload', path=fixture['files'][0]) == upload
        first.agent('post_message', request_id='attachment-message', text='Evidence attached.', attachment_ids=[upload['id']])
        unrelated = MCPClient(fixture)
        unrelated.join(fixture['sessions'][2]['invitations'][0], 'isolated')
        unrelated.call('read_attachment', dict(participant_token=unrelated.participant_token, attachment_id=attachment_ids['proposal.md']), error=True)
        state = first.agent('read_session')
        proposal = first.agent('propose_outcome', request_id='proposal-old', outcome='consensus', assessment='Bounded waits with cursor catch-up.', based_on_revision=state['revision'])
        first.agent('confirm_outcome', request_id='confirm-old', proposal_id=proposal['id'])
        second.agent('post_message', request_id='new-discussion', text='Also cancel waits on disconnect.')
        second.call('confirm_outcome', dict(participant_token=second.participant_token, request_id='stale-confirm', proposal_id=proposal['id']), error=True)
        assert first.agent('read_session')['proposal'] is None
        state = first.agent('read_session')
        proposal = second.agent('propose_outcome', request_id='proposal-new', outcome='consensus', assessment='Bounded waits, durable cursors, and cancellation on disconnect.', based_on_revision=state['revision'])
        assert first.agent('confirm_outcome', request_id='confirm-new-a', proposal_id=proposal['id'])['status'] == 'active'
        assert second.agent('confirm_outcome', request_id='confirm-new-b', proposal_id=proposal['id'])['status'] == 'consensus'
        first.call('post_message', dict(participant_token=first.participant_token, request_id='after-close', text='Cannot post'), error=True)
        resumed = MCPClient(fixture)
        resumed.participant_token = first.participant_token
        assert resumed.agent('read_session')['status'] == 'consensus'
        clients = [MCPClient(fixture) for _ in range(3)]
        for index, client in enumerate(clients):
            client.join(fixture['sessions'][1]['invitations'][index], 'tri-' + str(index))
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            posts = list(executor.map(lambda pair: pair[1].agent('post_message', request_id='peer-message', text='Perspective ' + str(pair[0])), enumerate(clients)))
        assert len({post['id'] for post in posts}) == 3
        state = clients[0].agent('read_session')
        proposal = clients[0].agent('propose_outcome', request_id='impasse', outcome='impasse', assessment='The peers disagree on the latency budget.', based_on_revision=state['revision'])
        for index, client in enumerate(clients):
            status = client.agent('confirm_outcome', request_id='tri-confirm', proposal_id=proposal['id'])['status']
            assert status == ('impasse' if index == 2 else 'active')
        all_events = []
        cursor = 0
        while True:
            batch = first.agent('read_events', after_cursor=cursor, limit=2)
            all_events += batch['events']
            cursor = batch['next_cursor']
            if not batch['has_more']:
                break
        assert len({e['id'] for e in all_events}) == len(all_events)
        assert [e['cursor'] for e in all_events] == list(range(1, cursor + 1))
        print('ARENA HTTP SMOKE PASSED')


if __name__ == '__main__':
    run()
