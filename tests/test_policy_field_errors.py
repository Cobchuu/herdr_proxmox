"""Policy rejections identify fields without persisting a partial policy."""
import json
import threading
import unittest
from unittest.mock import Mock
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from test_capture_and_build_install import contribution_case
from request_validation import FieldValidationError
import server


class PolicyFieldErrorTests(unittest.TestCase):
    def test_missing_validator_identifies_only_newly_enabled_rules(self):
        with contribution_case() as case:
            case.store.snapshot.return_value['organizations'] = [dict(id='org')]
            for changes, fields in ((dict(auto_capture=True, auto_validate=True), {'auto_validate'}),
                                    (dict(auto_validate=True, auto_publish=True), {'auto_validate', 'auto_publish'})):
                with self.assertRaises(FieldValidationError) as refused:
                    case.service.set_automation_policy(dict(organization_id='org', **changes), 'admin')
                self.assertEqual(set(refused.exception.field_errors), fields)
                self.assertIn('Validation is unavailable', str(refused.exception))
                self.assertFalse(case.service.policy('org')['auto_capture'])
                self.assertFalse(case.service.policy('org')['auto_validate'])

    def test_publication_dependencies_identify_the_publication_rule(self):
        with contribution_case() as case:
            case.store.snapshot.return_value['organizations'] = [dict(id='org')]
            case.service.validation = Mock()
            case.service.validation.snapshot.return_value = dict(executor='service')
            with self.assertRaises(FieldValidationError) as refused:
                case.service.set_automation_policy(dict(organization_id='org', auto_publish=True), 'admin')
            self.assertEqual(set(refused.exception.field_errors), {'auto_publish'})
            case.service.set_automation_policy(dict(organization_id='org', auto_validate=True), 'admin')
            case.api.snapshot.return_value = dict(configured=False)
            with self.assertRaises(FieldValidationError) as refused:
                case.service.set_automation_policy(dict(organization_id='org', auto_publish=True), 'admin')
            self.assertEqual(set(refused.exception.field_errors), {'auto_publish'})
            self.assertIn('Configure GitHub', str(refused.exception))
            self.assertFalse(case.service.policy('org')['auto_publish'])

    def test_invalid_flags_and_limits_identify_the_exact_key(self):
        with contribution_case() as case:
            case.store.snapshot.return_value['organizations'] = [dict(id='org')]
            for key, value in (('daily_cap', -1), ('max_active_sessions', 'many'), ('auto_capture', 'yes')):
                with self.assertRaises(FieldValidationError) as refused:
                    case.service.set_automation_policy(dict(organization_id='org', **{key: value}), 'admin')
                self.assertEqual(set(refused.exception.field_errors), {key})

    def test_http_response_retains_message_and_exposes_field_metadata(self):
        with contribution_case() as case:
            case.store.snapshot.return_value['organizations'] = [dict(id='org')]
            gateway = server.ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
            gateway.token, gateway.contributions = 'a' * 48, case.service
            thread = threading.Thread(target=gateway.serve_forever, daemon=True)
            thread.start()
            try:
                body = dict(request_id='policy-validation-fields', organization_id='org', auto_capture=True, auto_validate=True)
                request = Request(f'http://127.0.0.1:{gateway.server_port}/api/tasks/automation',
                                  data=json.dumps(body).encode(), headers={'Authorization': 'Bearer ' + gateway.token})
                with self.assertRaises(HTTPError) as refused:
                    urlopen(request)
                with refused.exception as response:
                    result = json.load(response)
                    self.assertEqual(response.code, 400)
                self.assertIn('Validation is unavailable', result['error'])
                self.assertEqual(result['field_errors'], dict(auto_validate=result['error']))
                self.assertFalse(case.service.policy('org')['auto_capture'])
            finally:
                gateway.shutdown()
                gateway.server_close()
                thread.join()
