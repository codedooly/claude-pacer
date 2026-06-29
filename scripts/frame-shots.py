#!/usr/bin/env python3
"""raw 캡처 → 둥근 모서리 + 그림자 + 여백 프레이밍 → assets/screenshot-*.png.

사용:
    python3 scripts/frame-shots.py            # assets/raw/*.png 를 매핑대로 처리
    python3 scripts/frame-shots.py --radius 28 --pad 64 --maxw 900

입력 파일명(assets/raw/) → 출력(assets/) 매핑:
    pace.png            → screenshot-pace.png
    usage.png           → screenshot-usage.png
    settings-cloud.png  → screenshot-settings-cloud.png
    settings-local.png  → screenshot-settings-local.png
    onboarding.png      → screenshot-onboarding.png   (로그인 게이트, 있으면)
    doctor.png          → screenshot-doctor.png       (Pacer 닥터, 있으면)
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "assets", "raw")
OUT = os.path.join(ROOT, "assets")

# 입력(raw) → 출력 파일명 매핑 (있는 것만 처리)
MAPPING = {
    "pace.png": "screenshot-pace.png",
    "usage.png": "screenshot-usage.png",
    "settings-cloud.png": "screenshot-settings-cloud.png",
    "settings-local.png": "screenshot-settings-local.png",
    "onboarding.png": "screenshot-onboarding.png",
    "doctor.png": "screenshot-doctor.png",
}


def autotrim(img: Image.Image, tol: int = 22) -> Image.Image:
    """카드 본체(가장 흔한 채움색)만 남기고 위·아래 팝오버 꼬리·잔여물·바깥 검정을 잘라낸다.

    좌상단 픽셀 기준 차분은 팝오버 꼬리(밝은 띠)·하단 글자를 못 거른다 →
    카드 채움색을 '최빈 색'으로 잡고, 그 색 영역의 bbox 로 크롭한다.
    """
    from PIL import ImageChops

    rgb = img.convert("RGB")
    small = rgb.resize((rgb.width // 4 or 1, rgb.height // 4 or 1))  # 최빈색 추출용 다운샘플
    fill = max(small.getcolors(small.width * small.height), key=lambda c: c[0])[1]

    # 채널별 |c - fill| ≤ tol 마스크를 AND → 카드 채움색 영역, 그 bbox = 카드 본체 (벡터 연산)
    masks = []
    for ch, f in zip(rgb.split(), fill):
        masks.append(ch.point(lambda v, f=f: 255 if abs(v - f) <= tol else 0))
    mask = ImageChops.multiply(ImageChops.multiply(masks[0], masks[1]), masks[2])
    bbox = mask.getbbox()
    return img.crop(bbox) if bbox else img


def crop_card_body(img: Image.Image, tol: int = 22) -> Image.Image:
    """팝오버 캡처에서 위쪽 메뉴바 스트립·삼각형 꼬리를 제거.

    메뉴바가 카드와 비슷한 어두운 색이라 autotrim 의 bbox 에 함께 들어온다.
    카드 채움색이 '가로로 넓게' 차는 행들의 '가장 긴 연속 블록' = 카드 본체.
    메뉴바(짧은 블록)와 그 아래 간격(desktop)·꼬리(좁음)는 본체와 분리되어 잘려나간다.
    """
    from PIL import ImageChops

    rgb = img.convert("RGB")
    small = rgb.resize((rgb.width // 4 or 1, rgb.height // 4 or 1))
    fill = max(small.getcolors(small.width * small.height), key=lambda c: c[0])[1]
    masks = [ch.point(lambda v, f=f: 255 if abs(v - f) <= tol else 0) for ch, f in zip(rgb.split(), fill)]
    mask = ImageChops.multiply(ImageChops.multiply(masks[0], masks[1]), masks[2])

    px = mask.load()
    w, h = mask.size
    step = 4  # 가로 샘플 간격
    cols = max(1, w // step)
    wide = [sum(1 for x in range(0, w, step) if px[x, y] > 0) / cols > 0.6 for y in range(h)]

    # 첫 '긴'(>=min_run) wide-run = 카드 본체. 위 메뉴바(짧음)·꼬리, 아래 데스크탑(별도 블록)은 제외.
    # 본체 내부 narrow 밴드(게이지·구분선)는 GAP 미만이라 런이 안 끊김. 본체 아래는 GAP 이상 narrow(모서리+간격)로 분리.
    min_run, GAP = 50, 8
    run_start, cur = None, None
    for y in range(h):
        if wide[y]:
            if cur is None:
                cur = y
            if y - cur + 1 >= min_run:
                run_start = cur
                break
        else:
            cur = None
    if run_start is None:
        return img
    _ = GAP
    # 상단은 run_start(본체 상단) 기준으로 정밀, 옆·아래는 균일 inset. 바닥은 둥근 모서리+데스크탑 sliver
    # 제거를 위해 옆/상단보다 크게 (데스크탑이 본체와 동색이라 바닥 자동검출 불안정 → 고정 마진).
    inset, bottom_inset = 18, 30
    top = run_start + inset
    return img.crop((inset, top, w - inset, h - bottom_inset))


def rounded(img: Image.Image, radius: int) -> Image.Image:
    """둥근 모서리 알파 마스크 적용."""
    img = img.convert("RGBA")
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], radius, fill=255)
    img.putalpha(mask)
    return img


def frame(img: Image.Image, radius: int, pad: int, blur: int, maxw: int) -> Image.Image:
    """둥근 카드 + 소프트 드롭섀도 + 투명 여백 (README 라이트/다크 양쪽 OK)."""
    card = rounded(img, radius)
    w, h = card.size
    canvas = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))

    # 그림자: 카드 실루엣을 블러 → 살짝 아래로 오프셋
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sil = Image.new("RGBA", card.size, (0, 0, 0, 150))
    sil.putalpha(card.split()[3].point(lambda a: int(a * 0.55)))
    shadow.paste(sil, (pad, pad + int(pad * 0.18)), sil)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))

    canvas = Image.alpha_composite(canvas, shadow)
    canvas.paste(card, (pad, pad), card)

    # 얇은 밝은 테두리 — 어두운 배경에서도 카드 위·왼쪽 윤곽이 묻히지 않도록 4면 정의
    border = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(
        [pad, pad, pad + w - 1, pad + h - 1], radius, outline=(255, 255, 255, 40), width=2
    )
    canvas = Image.alpha_composite(canvas, border)

    if maxw and canvas.size[0] > maxw:
        ratio = maxw / canvas.size[0]
        canvas = canvas.resize((maxw, int(canvas.size[1] * ratio)), Image.LANCZOS)
    return canvas


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--radius", type=int, default=26, help="모서리 반경(px, 다운스케일 전)")
    ap.add_argument("--pad", type=int, default=60, help="그림자용 여백(px)")
    ap.add_argument("--blur", type=int, default=28, help="그림자 블러 반경")
    ap.add_argument("--maxw", type=int, default=900, help="출력 최대 너비(px, 0=원본)")
    ap.add_argument("--no-trim", action="store_true", help="autotrim 비활성")
    args = ap.parse_args()

    if not os.path.isdir(RAW):
        print(f"입력 폴더 없음: {RAW}\n→ 여기에 pace.png / usage.png / settings-cloud.png / settings-local.png 저장")
        return 1

    done = 0
    for src, dst in MAPPING.items():
        p = os.path.join(RAW, src)
        if not os.path.exists(p):
            continue
        img = Image.open(p)
        if not args.no_trim:
            img = autotrim(img)
            if src in ("pace.png", "usage.png", "onboarding.png"):   # 팝오버 — 위쪽 메뉴바·꼬리 제거
                img = crop_card_body(img)
        out = frame(img, args.radius, args.pad, args.blur, args.maxw)
        out_path = os.path.join(OUT, dst)
        out.save(out_path)
        print(f"✓ {src:24} → assets/{dst}  ({out.size[0]}x{out.size[1]})")
        done += 1

    # hero.png — 현재 Pace 카드로 갱신 (README 최상단 히어로)
    pace = os.path.join(RAW, "pace.png")
    if os.path.exists(pace):
        img = Image.open(pace)
        if not args.no_trim:
            img = autotrim(img)
            img = crop_card_body(img)   # pace 는 팝오버 — 메뉴바·꼬리 제거
        hero = frame(img, args.radius, args.pad, args.blur, 600)
        hero.save(os.path.join(OUT, "hero.png"))
        print(f"✓ {'pace.png':24} → assets/hero.png  ({hero.size[0]}x{hero.size[1]})")
        done += 1

    if not done:
        print(f"처리할 파일 없음. {RAW} 에 pace.png 등 매핑된 이름으로 저장하세요.")
        return 1
    print(f"\n완료: {done}장 → assets/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
