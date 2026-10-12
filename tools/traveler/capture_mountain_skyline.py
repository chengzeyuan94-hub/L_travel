import importlib.util
from pathlib import Path
s=importlib.util.spec_from_file_location('capture','tools/traveler/capture_mountain_views.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
m.OUT=Path.cwd()/'docs/design/shanhe-luren/mountain-rework/skyline-height'
m.VIEWS=[(f'{period}-{kind}','--'+period,(['--capture-preview']+m.NODOF if kind=='clear' else ['--capture-preview'])) for period in ['day','dusk'] for kind in ['clear','dof']]
m.main()
