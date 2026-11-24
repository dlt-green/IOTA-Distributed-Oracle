"""Freeze previously approved template configuration into the fresh init only.

No public setter or registration bypass is introduced. --fetch reads the old
deployment; --check proves the checked-in snapshot matches the generated source.
"""
import argparse
import json
from pathlib import Path
import re
import urllib.request

ROOT = Path(__file__).resolve().parent
STATE = '0xbc26a14811f13dedd991f0fb229c336ad74e92c108c896bfb683820844a24903'
PACKAGE = '0x55a6b6848a5a343a8ad5ec5db46a93b15011bc3e50fd164e03d996f1aa317425'
SNAPSHOT = ROOT / 'approved_templates_snapshot.json'
SOURCE = ROOT / 'oracle_system_state_testnet/sources/iota_oracle_system_state.move'

def rpc(method, params):
    request = urllib.request.Request('https://api.testnet.iota.cafe',
        data=json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=params)).encode(),
        headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.load(response)
    if 'error' in result:
        raise RuntimeError(result['error'])
    return result['result']

def fetch_snapshot():
    state = rpc('iota_getObject', [STATE, {'showContent': True}])['data']
    fields = state['content']['fields']
    assert fields['system_fee_bps'] == '500' and fields['min_payment'] == '0'
    templates, cursor = [], None
    while True:
        page = rpc('iotax_getDynamicFields', [STATE, cursor, 50])
        ids = [x['objectId'] for x in page['data'] if x['name']['type'] == PACKAGE + '::systemState::TaskTemplateKey']
        if ids:
            for obj in rpc('iota_multiGetObjects', [ids, {'showContent': True}]):
                data = obj['data']
                value = data['content']['fields']['value']
                assert value['type'] == PACKAGE + '::systemState::TaskTemplate'
                templates.append(dict(object_id=data['objectId'], version=data['version'], fields=value['fields']))
        if not page['hasNextPage']:
            break
        cursor = page['nextCursor']
    latest = rpc('iota_getObject', [STATE, {'showContent': True}])['data']
    assert state['version'] == latest['version'], 'Source State changed during snapshot; retry'
    assert templates, 'No approved templates found'
    return dict(source_state=STATE, source_version=state['version'],
                templates=sorted(templates, key=lambda t: int(t['fields']['template_id'])))

def render(snapshot):
    lines = ['    // BEGIN APPROVED TEMPLATE SNAPSHOT',
             '    // Frozen approved configuration; executed only by module init.',
             '    fun bootstrap_approved_templates(st: &mut State) {']
    seen = set()
    for item in snapshot['templates']:
        fields = item['fields']
        tid = int(fields['template_id'])
        assert tid not in seen
        seen.add(tid)
        lines.append(f'        dynamic_field::add(&mut st.id, TaskTemplateKey {{ template_id: {tid} }}, TaskTemplate {{')
        for key, value in fields.items():
            assert re.fullmatch('[a-z_]+', key)
            if key == 'task_type':
                assert all(isinstance(n, int) and 0 <= n <= 255 for n in value)
                literal = 'vector[' + ', '.join(map(str, value)) + ']'
            else:
                assert 0 <= int(value) < 2**64
                literal = str(int(value))
            lines.append(f'            {key}: {literal},')
        lines.append('        });')
    lines.extend(['    }', '    // END APPROVED TEMPLATE SNAPSHOT'])
    return '\n'.join(lines)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--fetch', action='store_true')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if args.fetch:
        SNAPSHOT.write_text(json.dumps(fetch_snapshot(), indent=2) + '\n', encoding='utf-8')
    snapshot = json.loads(SNAPSHOT.read_text(encoding='utf-8'))
    text = SOURCE.read_text(encoding='utf-8')
    generated = render(snapshot)
    updated, count = re.subn(r'    // BEGIN APPROVED TEMPLATE SNAPSHOT.*?    // END APPROVED TEMPLATE SNAPSHOT', generated, text, flags=re.S)
    assert count == 1
    if args.check:
        assert updated == text, 'Bootstrap differs from reviewed template snapshot'
    else:
        SOURCE.write_text(updated, encoding='utf-8')
    print(f"Approved template snapshot: {len(snapshot['templates'])} templates; source version {snapshot['source_version']}")
