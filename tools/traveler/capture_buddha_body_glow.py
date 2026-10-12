"""Dusk-only concealed Buddha light, fixed-camera render comparison."""
import importlib.util
from pathlib import Path
root=Path(__file__).resolve().parents[2]
s=importlib.util.spec_from_file_location('capture',root/'tools/traveler/capture_mountain_views.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
m.OUT=root/'docs/reports/traveler-cliff-buddha-v2/body-glow'
m.VIEWS=[(f'{version}-{period}-{kind}','--'+period,['--capture-preview']+(m.NODOF if kind=='clear' else [])+(['--no-buddha-body-glow'] if version=='before' else [])) for version in ['before','after'] for period in ['day','dusk'] for kind in ['clear','dof']]
m.VIEWS.append(('after-night-dof','--dusk',['--capture-preview','--night']))
if __name__=='__main__':
    import json
    if 'body_glow' not in json.loads((root/'data/traveler/cliff_buddha_v2_params.json').read_text()):
        raise SystemExit('Historical light setup retired. Use capture_buddha_self_emission.py for the current material emission.')
    m.main()
