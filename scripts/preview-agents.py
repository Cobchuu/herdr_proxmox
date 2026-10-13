"""Simulated agent commands shared by disposable native-dashboard previews.

This fixture does not launch real agents or change container configuration.
"""
import json
from pathlib import Path
import re
import time
import uuid


class MockHerdr:
    def __init__(self):
        self.agents = {}
        self.workspaces = []
        self.outputs = {}

    def command(self, *args, **kwargs):
        if args == ('api', 'schema', '--json'):
            return {'schemas': {'success_response': {'$defs': {'AgentInfo': {'properties': {k: {} for k in ('name', 'pane_id', 'agent', 'agent_status')}}}}}}
        if args[:2] == ('workspace', 'create'):
            number = len(self.workspaces) + 1
            self.workspaces.append({'workspace_id': f'w{number}', 'label': args[args.index('--label') + 1]})
            return {'root_pane': {'pane_id': f'w{number}:p1'}}
        if args[:2] == ('workspace', 'list'):
            return {'workspaces': self.workspaces}
        if args[:2] == ('agent', 'list'):
            return {'agents': list(self.agents.values())}
        if args[:2] == ('pane', 'process-info'):
            return {'process_info': {'shell_pid': 42, 'foreground_process_group_id': 42}}
        if args[:2] == ('agent', 'start'):
            self.agents[args[2]] = dict(name=args[2], pane_id=args[6], agent=args[4], agent_status='idle', agent_session={'value': uuid.uuid4().hex})
            return {'agent': self.agents[args[2]]}
        if args[:2] == ('agent', 'get'):
            return {'agent': self.agents[args[2]]}
        if args[:2] == ('agent', 'read'):
            return {'output': self.outputs.get(args[2], 'Mock agent ready.')}
        if args[:2] == ('agent', 'send-keys'):
            self.agents[args[2]]['agent_status'] = 'idle'
            self.outputs[args[2]] = f'Mock terminal received {args[3]}.'
            return {}
        if args[:2] == ('agent', 'prompt'):
            alias, prompt = args[2:4]
            self.agents[alias]['agent_status'] = 'working'
            time.sleep(0.5)
            path = re.search(r'exactly (?:this new file: )?(.+?\.md)', prompt)
            if path:
                final = 'Synthesize the discussion' in prompt or 'You are the group conversation' in prompt
                content = ('# Action brief (mock)\n\n1. Compare deployment options.\n2. Prototype the recommended option.\n3. Review evidence before rollout.\n\n## Risks\nCapacity and recovery have not been verified.\n\n## Acceptance criteria\nA successful backup and restore rehearsal.\n' if final else '# Proposal (mock)\n\nUse a staged deployment with a tested rollback. Review the other proposals and verify capacity before choosing.\n')
                Path(path[1]).write_text(content, encoding='utf-8')
                self.outputs[alias] = content
                transcript = re.search(r'Also write (.+?discussion\.json)', prompt)
                if transcript:
                    ids = json.loads(re.search(r'Profile IDs: (.+?)\. Record', prompt)[1])
                    parts = []
                    for round_number in (1, 2):
                        for member_alias, profile_id in ids.items():
                            self.agents[member_alias]['agent_status'] = 'working'
                            self.outputs[alias] = f'Mock facilitator: asking a member for round {round_number}.'
                            self.outputs[member_alias] = 'Mock member: comparing deployment options…'
                            time.sleep(1.5)
                            reply = 'Mock member response: use a staged deployment and rehearse recovery.'
                            parts.append(dict(profile_id=profile_id, name='mock', round=round_number, content=reply))
                            Path(transcript[1]).write_text(json.dumps({'contributions': parts}), encoding='utf-8')
                            self.outputs[member_alias] = reply
                            self.agents[member_alias]['agent_status'] = 'idle'
                    self.outputs[alias] = content
            elif 'mock:block' in prompt:
                self.agents[alias]['agent_status'] = 'blocked'
                self.outputs[alias] = 'Mock permission request: Allow this action? Use Enter to accept or Escape to dismiss.'
                return {}
            else:
                self.outputs[alias] = f'You: {prompt[-300:]}\n\nMax (mock): I can help review the design. Start by defining the goal, constraints, and acceptance criteria.'
            self.agents[alias]['agent_status'] = 'idle'
            return {}
        raise ValueError('This operation is not supported by the local mock preview.')

