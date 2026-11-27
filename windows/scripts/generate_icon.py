from pathlib import Path
from PIL import Image, ImageDraw

out_path = Path("windows/UniBridge.App/Assets/UniBridge.ico")
out_path.parent.mkdir(parents=True, exist_ok=True)

size = 256
img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Outer blue rounded square badge
draw.rounded_rectangle([(8, 8), (248, 248)], radius=52, fill=(37, 99, 235, 255))
draw.rounded_rectangle([(18, 18), (238, 238)], radius=44, outline=(147, 197, 253, 190), width=4)

# Drive body
draw.rounded_rectangle([(56, 62), (200, 148)], radius=20, fill=(255, 255, 255, 248))
# USB plug neck & pins
draw.rounded_rectangle([(84, 150), (172, 196)], radius=8, fill=(219, 234, 254, 245))
draw.rectangle([(102, 162), (118, 180)], fill=(37, 99, 235, 255))
draw.rectangle([(138, 162), (154, 180)], fill=(37, 99, 235, 255))

# Dual-direction transfer chevrons on drive face
draw.polygon([(78, 92), (138, 92), (138, 81), (168, 99), (138, 117), (138, 106), (78, 106)], fill=(20, 184, 166, 255))
draw.polygon([(178, 118), (118, 118), (118, 107), (88, 125), (118, 143), (118, 132), (178, 132)], fill=(37, 99, 235, 255))

img.save(
    out_path,
    format="ICO",
    sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)],
)
print(f"Generated {out_path}")
