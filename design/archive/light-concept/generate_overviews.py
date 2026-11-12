#!/usr/bin/env python3
"""Regenerate the archived light/orange concept, not the current dark iOS layout."""

from pathlib import Path
import json

OUT = Path(__file__).resolve().parent
W, H = 393, 440
SW, SH, GAP, AISLE, ROW_GAP = 17.4, 18.4, 3.0, 11.5, 25.0
GRID_W = 14 * SW + 13 * GAP + 2 * AISLE
START_X = (W - GRID_W) / 2
START_Y = 79.0
EXCLUDED = {"G08", "G09", "C08", "G03"}


def pos(r, c):
    return START_X + c * (SW + GAP) + (AISLE if c >= 4 else 0) + (AISLE if c >= 10 else 0), START_Y + r * ROW_GAP


def is_sold(r, c):
    sid = f"{chr(65 + r)}{c + 1:02d}"
    return sid not in EXCLUDED and ((r * 11 + c * 7) % 19 in (0, 1, 5, 8, 12) or (r == 4 and c in (4, 5, 6, 7)))


DEFS = '''<defs>
  <linearGradient id="floor" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#E7E8E2"/><stop offset="1" stop-color="#F5F5EF"/></linearGradient>
  <linearGradient id="wallL" x1="0" y1="0" x2="1" y2="0"><stop stop-color="#FFFFFF"/><stop offset=".5" stop-color="#F7F7F1"/><stop offset="1" stop-color="#D9DAD4"/></linearGradient>
  <linearGradient id="wallR" x1="1" y1="0" x2="0" y2="0"><stop stop-color="#FFFFFF"/><stop offset=".5" stop-color="#F7F7F1"/><stop offset="1" stop-color="#D9DAD4"/></linearGradient>
  <linearGradient id="screen" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#FFFFFF"/><stop offset=".55" stop-color="#FCFCF8"/><stop offset="1" stop-color="#D5D8D1"/></linearGradient>
  <linearGradient id="back-available" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#FFFFFF"/><stop offset=".48" stop-color="#FDFDF9"/><stop offset="1" stop-color="#E2E3DC"/></linearGradient>
  <linearGradient id="cushion-available" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#FAFAF6"/><stop offset=".55" stop-color="#F3F4ED"/><stop offset="1" stop-color="#DADCD3"/></linearGradient>
  <linearGradient id="back-sold" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#D6D8D1"/><stop offset=".55" stop-color="#CFD2C9"/><stop offset="1" stop-color="#B8BEB1"/></linearGradient>
  <linearGradient id="cushion-sold" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#CED1C8"/><stop offset="1" stop-color="#B6BDAF"/></linearGradient>
  <linearGradient id="back-selected" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#FF8A42"/><stop offset=".48" stop-color="#FF752C"/><stop offset="1" stop-color="#EC5716"/></linearGradient>
  <linearGradient id="cushion-selected" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#FF762C"/><stop offset="1" stop-color="#E45214"/></linearGradient>
  <linearGradient id="steps" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#F9F9F3"/><stop offset="1" stop-color="#DDDFD5"/></linearGradient>
</defs>'''


def seat(r, c, selected):
    sid = f"{chr(65 + r)}{c + 1:02d}"
    state = "selected" if sid in selected else "sold" if is_sold(r, c) else "available"
    x, y = pos(r, c)
    # Each surface is a genuine vector path. No blur/filter/raster fallback.
    arm = {"available": "#F7F7F0", "sold": "#C8CCC0", "selected": "#FF7A30"}[state]
    edge = {"available": "#D7DAD0", "sold": "#AFB7A5", "selected": "#D94C0C"}[state]
    return f'''<g id="seat-{sid}" data-state="{state}" transform="translate({x:.2f} {y:.2f})">
  <path id="seat-{sid}-shadow" d="M1.7 4.8Q1.7 2.7 4 2.7H14Q16.3 2.7 16.3 4.8V17.7Q16.3 20.1 13.6 20.1H4.3Q1.7 20.1 1.7 17.7Z" fill="#8D9585" opacity=".16"/>
  <path id="seat-{sid}-base" d="M1.6 6.9H15.8V16.1Q15.8 18.8 13.1 18.8H4.3Q1.6 18.8 1.6 16.1Z" fill="{edge}"/>
  <path id="seat-{sid}-cushion" d="M2.6 7.5H14.8V15.5Q14.8 17.7 12.6 17.7H4.8Q2.6 17.7 2.6 15.5Z" fill="url(#cushion-{state})"/>
  <path id="seat-{sid}-backrest" d="M2.2 1.5Q2.2 0 4 0H13.4Q15.2 0 15.2 1.5V7.7Q15.2 9.7 13.2 9.7H4.2Q2.2 9.7 2.2 7.7Z" fill="url(#back-{state})"/>
  <path id="seat-{sid}-top-highlight" d="M4.3 .65H13.1Q14.35 .65 14.35 1.8V2.3H3.05V1.8Q3.05 .65 4.3 .65Z" fill="#FFFFFF" opacity="{'.30' if state == 'selected' else '.52'}"/>
  <path id="seat-{sid}-arm-left" d="M.6 6.2Q.6 5.4 1.5 5.4H2Q2.9 5.4 2.9 6.2V14.6Q2.9 15.5 2 15.5H1.5Q.6 15.5 .6 14.6Z" fill="{arm}"/>
  <path id="seat-{sid}-arm-right" d="M14.5 6.2Q14.5 5.4 15.4 5.4H15.9Q16.8 5.4 16.8 6.2V14.6Q16.8 15.5 15.9 15.5H15.4Q14.5 15.5 14.5 14.6Z" fill="{arm}"/>
</g>'''


def scene(selected):
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">', DEFS]
    parts.append('''<rect id="warm-grey-ground" width="393" height="440" fill="#EEEDE8"/>
<g id="auditorium-shell">
  <path id="shell-shadow" d="M34 58Q34 45 48 45H345Q359 45 359 58V384Q359 403 340 407H53Q34 403 34 384Z" fill="#B6BCAF" opacity=".18"/>
  <path id="floor-platform" d="M35 54Q35 44 47 44H346Q358 44 358 54V379Q358 393 344 393H49Q35 393 35 379Z" fill="url(#floor)"/>
  <path id="screen-shadow" d="M63 40Q196.5 22 330 40V46Q196.5 31 63 46Z" fill="#CFD4C8" opacity=".5"/>
  <path id="cinema-screen" d="M63 31Q196.5 10 330 31V40Q196.5 22 63 40Z" fill="url(#screen)"/>
  <path id="screen-light-edge" d="M64 31Q196.5 11 329 31" fill="none" stroke="#FFFFFF" stroke-width="1.8"/>
  <path id="stage-top" d="M78 53Q196.5 40 315 53L307 59Q196.5 49 86 59Z" fill="#E0E3D9"/>
  <path id="stage-front" d="M86 59Q196.5 49 307 59V62Q196.5 52 86 62Z" fill="#D6DBCD"/>
  <path id="wall-left" d="M24 61Q24 51 34 51H38V382H34Q24 382 24 372Z" fill="url(#wallL)"/>
  <path id="wall-right" d="M369 61Q369 51 359 51H355V382H359Q369 382 369 372Z" fill="url(#wallR)"/>
  <path id="wall-left-cap" d="M25 60Q25 52 34 52H37V56H34Q29 56 29 61V372H25Z" fill="#FFFFFF" opacity=".8"/>
  <path id="wall-right-cap" d="M368 60Q368 52 359 52H356V56H359Q364 56 364 61V372H368Z" fill="#FFFFFF" opacity=".8"/>
</g>''')
    for r in range(12):
        y = START_Y + r * ROW_GAP
        parts.append(f'<path id="riser-{chr(65+r)}" d="M42 {y+22:.2f}H351" stroke="#D2D8C9" stroke-width=".7" opacity=".48"/>')
    parts.append('<g id="seating-grid">')
    for r in range(12):
        parts.append(f'<g id="row-{chr(65+r)}">')
        for c in range(14):
            parts.append(seat(r, c, selected))
        parts.append('</g>')
    parts.append('''</g>
<g id="entrance-steps">
  <path id="rear-landing" d="M42 385H351V394Q351 401 343 401H50Q42 401 42 394Z" fill="url(#steps)"/>
  <path id="entry-step-1" d="M151 401H242V407H151Z" fill="#D8DDCF"/>
  <path id="entry-step-2" d="M144 407H249V413H144Z" fill="#E6E9DE"/>
  <path id="entry-step-3" d="M138 413H255V419H138Z" fill="#F6F6EF"/>
  <path id="entry-highlight" d="M138 413H255" stroke="#FFFFFF" stroke-width="1.4"/>
</g></svg>''')
    return '\n'.join(parts)


def main():
    variants = {"default": set(), "single": {"G08"}, "pair": {"G08", "G09"}, "side": {"G03"}, "front": {"C08"}}
    for name, selected in variants.items():
        (OUT / f"overview-{name}.svg").write_text(scene(selected), encoding="utf-8")
    seats = []
    for r in range(12):
        for c in range(14):
            x, y = pos(r, c)
            sid = f"{chr(65+r)}{c+1:02d}"
            base = "sold" if is_sold(r,c) else "available"
            seats.append({"id":f"seat-{sid}", "seatId":sid, "row":r+1, "rowLetter":chr(65+r), "number":c+1, "x":round(x,2), "y":round(y,2), "width":SW, "height":SH, "centerX":round(x+SW/2,2), "centerY":round(y+SH/2,2), "status":base, "states":{name: "selected" if sid in selected else base for name, selected in variants.items()}})
    (OUT / "seat-layout.json").write_text(json.dumps({"width":W,"height":H,"rows":12,"columns":14,"background":"#EEEDE8","aislesAfterColumns":[4,10],"seatCount":len(seats),"selectedByVariant":{k:sorted(v) for k,v in variants.items()},"seats":seats},ensure_ascii=False,indent=2), encoding="utf-8")
    print(json.dumps({"files":[str(OUT/f"overview-{v}.svg") for v in variants],"layout":str(OUT/"seat-layout.json"),"seats":len(seats),"available":sum(s['status']=='available' for s in seats)},ensure_ascii=False))


if __name__ == "__main__":
    main()
