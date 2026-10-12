"""Capture the authored near mountain in the frozen camera, before/after and DOF."""
import importlib.util
from pathlib import Path
root=Path(__file__).resolve().parents[2]
s=importlib.util.spec_from_file_location('capture',root/'tools/traveler/capture_mountain_views.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
m.OUT=root/'docs/reports/traveler-near-mountain-001/evidence'
m.VIEWS=[(f'{version}-{period}-{kind}','--'+period,['--capture-preview']+(m.NODOF if kind=='clear' else [])+(['--no-near-mountain'] if version=='before' else ['--near-mountain-preview'])) for version in ['before','after'] for period in ['day','dusk'] for kind in ['clear','dof']]
if __name__=='__main__':m.main()
