"""Request-key syntax shared by persisted, endpoint-specific replay contracts."""
import re

REQUEST_CHARACTERS = r'[A-Za-z0-9_-]'


def request_pattern(minimum=1, maximum=64):
    return re.compile(REQUEST_CHARACTERS + '{' + str(minimum) + ',' + str(maximum) + '}')


ORGANIZATION_REQUEST = request_pattern(8, 80)
TASK_REQUEST = request_pattern()
