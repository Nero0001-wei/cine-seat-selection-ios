#!/usr/bin/env python3
"""Export public design geometry from the checked-in Swift theater model.

Only scalar model constants and seat identifiers are parsed. Geometry formulas
mirror TheaterLayout; update this exporter if those Swift formulas change.
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import re


def export(model):
    source = model.read_text(encoding="utf-8")

    def scalar(name):
        match = re.search(r"static let " + re.escape(name) + r"(?:\s*:\s*\w+)?\s*=\s*(-?\d+(?:\.\d+)?)\b", source)
        if not match:
            raise ValueError("Missing numeric Swift constant: " + name)
        value = float(match.group(1))
        return int(value) if value.is_integer() else value

    names = ["rowCount", "columnCount", "columnPitch", "rowPitch", "rowRise",
             "firstRowZ", "crossAisleWidth", "floorWidth", "sideAisleX",
             "roomFrontZ", "overviewSpan", "overviewCenterZ", "screenWidth",
             "filmDepthOffset", "frameDepthOffset", "seatedEyeBaseHeight",
             "seatedEyeForwardOffset", "seatBackrestHeight",
             "seatBackrestTopZOffset", "sightlineClearance"]
    c = {name: scalar(name) for name in names}
    sold_block = re.search(r"static let soldIDs: Set<String>\s*=\s*\[(.*?)\]", source, re.S)
    if not sold_block:
        raise ValueError("Missing soldIDs")
    sold = sorted(set(re.findall(r'"([A-L]\d{2})"', sold_block.group(1))))
    aisles_match = re.search(r"static let crossAisles\s*=\s*\[(.*?)\]", source)
    if not aisles_match:
        raise ValueError("Missing crossAisles")
    after_rows = [int(n) for n in re.findall(r"afterRow:\s*(\d+)", aisles_match.group(1))]
    sections = []
    for key in ["front", "middle", "rear"]:
        m = re.search(r"case \." + key + r":\s*(\d+)\.\.\.(\d+)", source)
        if not m:
            raise ValueError("Missing section rows: " + key)
        sections.append({"id": key, "label": {"front": "前区", "middle": "中区", "rear": "后区"}[key],
                         "rows": list(range(int(m.group(1)), int(m.group(2)) + 1))})

    def row_z(row):
        return c["firstRowZ"] + (row - 1) * c["rowPitch"] + sum(n < row for n in after_rows) * c["crossAisleWidth"]

    def elevation(row):
        return (row - 1) * c["rowRise"]

    def number(value):
        return round(value, 6) + 0.0

    def vector(x, y, z):
        return [number(x), number(y), number(z)]

    film_height = c["screenWidth"] * 9 / 16
    frame_width = c["screenWidth"] + 0.24
    frame_height = film_height + 0.24
    screen_radius = 29.4 * (c["screenWidth"] / 10.8)
    center_y = 0.395 + frame_height / 2
    center_z = c["roomFrontZ"] + 0.3
    bottom_y = center_y - frame_height / 2
    bow = screen_radius - math.sqrt(screen_radius * screen_radius - (frame_width / 2) ** 2)
    bottom_z = center_z + c["frameDepthOffset"] + bow

    def eye_height(row):
        floor = elevation(row)
        eye_z = row_z(row) + c["seatedEyeForwardOffset"]
        eye_depth = eye_z - bottom_z
        minimum_y = floor + c["seatedEyeBaseHeight"]
        if row <= 1 or eye_depth <= 0:
            return c["seatedEyeBaseHeight"]
        for previous in range(1, row):
            backrest_y = elevation(previous) + c["seatBackrestHeight"]
            backrest_z = row_z(previous) + c["seatBackrestTopZOffset"]
            depth = backrest_z - bottom_z
            if 0 < depth < eye_depth:
                needed = bottom_y + (backrest_y + c["sightlineClearance"] - bottom_y) * eye_depth / depth
                minimum_y = max(minimum_y, needed)
        return minimum_y - floor

    seats = []
    rows = []
    for row in range(1, c["rowCount"] + 1):
        section = next(section["id"] for section in sections if row in section["rows"])
        eye = eye_height(row)
        rows.append({"row": row, "letter": chr(64 + row), "section": section,
                     "z": number(row_z(row)), "elevation": number(elevation(row)),
                     "seatedEyeHeightAboveRow": number(eye)})
        for column in range(1, c["columnCount"] + 1):
            seat_id = chr(64 + row) + f"{column:02d}"
            x = (column - (c["columnCount"] + 1) / 2) * c["columnPitch"]
            seats.append({"id": seat_id, "row": row, "column": column,
                          "section": section, "status": "sold" if seat_id in sold else "available",
                          "position": vector(x, elevation(row), row_z(row)),
                          "seatedEyePosition": vector(x, elevation(row) + eye, row_z(row) + c["seatedEyeForwardOffset"])})
    cross_aisles = []
    for after_row in after_rows:
        start = row_z(after_row) + c["rowPitch"] / 2
        end = start + c["crossAisleWidth"]
        cross_aisles.append({"afterRow": after_row, "width": c["crossAisleWidth"],
                            "startZ": number(start), "endZ": number(end),
                            "centerZ": number((start + end) / 2), "elevation": number(elevation(after_row))})
    room_back = row_z(c["rowCount"]) + 2.2
    return {
        "formatVersion": 1,
        "title": "CINÉ · 当前连续排座与阶梯影厅",
        "source": "iOSDemo/CinemaDemo/Models/CinemaModel.swift",
        "sourceSha256": hashlib.sha256(source.encode("utf-8")).hexdigest(),
        "unit": "m",
        "coordinateSystem": {"x": "向右", "y": "向上", "z": "向影厅后部；银幕位于负z方向"},
        "precision": "导出坐标四舍五入至6位小数；运行时使用Swift Float。",
        "constants": c,
        "seatCount": len(seats), "soldCount": len(sold), "availableCount": len(seats) - len(sold),
        "soldIDs": sold, "sections": sections, "crossAisles": cross_aisles,
        "rowZFormula": "firstRowZ + (row - 1) * rowPitch + precedingCrossAisleCount * crossAisleWidth",
        "rowElevationFormula": "(row - 1) * rowRise",
        "columnXFormula": "(column - (columnCount + 1) / 2) * columnPitch",
        "rows": rows, "seats": seats,
        "presets": {"center": "G08", "side": "G03", "front": "C08", "rear": "K08"},
        "room": {"frontZ": c["roomFrontZ"], "backZ": number(room_back),
                 "depth": number(room_back - c["roomFrontZ"]),
                 "centerZ": number((room_back + c["roomFrontZ"]) / 2),
                 "floorWidth": c["floorWidth"], "sideAisleX": c["sideAisleX"]},
        "screen": {"filmWidth": c["screenWidth"], "filmHeight": number(film_height),
                   "frameWidth": number(frame_width), "frameHeight": number(frame_height),
                   "radius": number(screen_radius), "centerPosition": vector(0, center_y, center_z),
                   "conservativeBottomSightlineTarget": vector(0, bottom_y, bottom_z),
                   "filmDepthOffset": c["filmDepthOffset"], "frameDepthOffset": c["frameDepthOffset"]},
        "note": "库存与座位价格均为本机演示数据；本JSON不含影片、贴图或用户数据。"
    }


def main():
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=repo / "iOSDemo/CinemaDemo/Models/CinemaModel.swift")
    parser.add_argument("--output", type=Path, default=repo / "design/latest/theater-layout.json")
    args = parser.parse_args()
    result = export(args.model)
    if result["seatCount"] != result["constants"]["rowCount"] * result["constants"]["columnCount"]:
        raise ValueError("Seat count does not match the model")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"seats": result["seatCount"], "sold": result["soldCount"],
                      "rows": result["constants"]["rowCount"], "crossAisles": len(result["crossAisles"])}, ensure_ascii=False))


if __name__ == "__main__":
    main()
