"""Rebuild compact SVGs for the archived light/orange concept."""
from pathlib import Path
import xml.etree.ElementTree as ET
from copy import deepcopy
import subprocess
import sys

ROOT = Path(__file__).resolve().parent

# A public checkout contains compact SVGs. Generate editable expanded sources first.
if any(not (ROOT / f"overview-{key}.svg").is_file() for key in ["default", "single", "pair", "side", "front"]):
    subprocess.run([sys.executable, str(ROOT / "generate_overviews.py")], check=True)
NS='http://www.w3.org/2000/svg'
XL='http://www.w3.org/1999/xlink'
ET.register_namespace('',NS)
ET.register_namespace('xlink',XL)
for key in ['default','single','pair','side','front']:
    doc=ET.fromstring((ROOT/f'overview-{key}.svg').read_text(encoding='utf-8'))
    defs=doc.find(f'{{{NS}}}defs')
    templates={}
    for group in doc.iter(f'{{{NS}}}g'):
        if 'data-state' in group.attrib and group.attrib['data-state'] not in templates:
            template=deepcopy(group)
            state=group.attrib['data-state']
            template.attrib={'id':f'seat-shape-{state}'}
            for ch in template:
                ch.attrib.pop('id',None)
            templates[state]=template
    # Default SVG lacks a selected seat, so source that template from single.
    if 'selected' not in templates:
        source=ET.fromstring((ROOT/'overview-single.svg').read_text(encoding='utf-8'))
        target=next(g for g in source.iter(f'{{{NS}}}g') if g.attrib.get('data-state')=='selected')
        template=deepcopy(target);template.attrib={'id':'seat-shape-selected'}
        for ch in template: ch.attrib.pop('id',None)
        templates['selected']=template
    for template in templates.values(): defs.append(template)
    for group in doc.iter(f'{{{NS}}}g'):
        if 'data-state' not in group.attrib: continue
        state=group.attrib.pop('data-state')
        for ch in list(group): group.remove(ch)
        ET.SubElement(group,f'{{{NS}}}use',{f'{{{XL}}}href':f'#seat-shape-{state}'})
    (ROOT/f'overview-{key}-compact.svg').write_text(ET.tostring(doc,encoding='unicode'), encoding='utf-8')
