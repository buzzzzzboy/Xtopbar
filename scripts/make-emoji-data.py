#!/usr/bin/env python3
"""生成表情符號選擇器的資料檔 Resources/Emoji.tsv。

資料來源（先下載到一個空目錄，再把目錄傳進來）：
  Unicode emoji-test.txt   https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt
  CLDR 註解（名稱 + 關鍵字）  https://github.com/unicode-org/cldr/tree/main/common/annotations
                             https://github.com/unicode-org/cldr/tree/main/common/annotationsDerived
    存成 ann-<lang>.xml / der-<lang>.xml，lang = en、zh_Hant、zh

用法：
  python3 -I scripts/make-emoji-data.py <下載目錄> Resources/Emoji.tsv Resources/SymbolNames.tsv

輸出每行一個表情（不含膚色變體，膚色在 App 裡按偏好套上），欄位以 Tab 分隔：
  emoji  分類序號  Unicode 版本  膚色變體(5 個，空格分隔；不支援膚色為空)
  en 名稱  en 關鍵字(|分隔)  zh_Hant 名稱  zh_Hant 關鍵字  zh 名稱  zh 關鍵字

SymbolNames.tsv：CLDR 裡其它非表情字元（箭頭、數學符號、貨幣…）的名稱與關鍵字，
給「特殊符號」分類用（字元本身來自系統「字元檢視器」的分類表），欄位：
  字元  en 名稱  en 關鍵字  zh_Hant 名稱  zh_Hant 關鍵字  zh 名稱  zh 關鍵字
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

GROUPS = [
    "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink",
    "Travel & Places", "Activities", "Objects", "Symbols", "Flags",
]
TONES = [chr(c) for c in range(0x1F3FB, 0x1F400)]
LANGS = ["en", "zh_Hant", "zh"]


def key(s: str) -> str:
    """比對用：去掉 FE0F（CLDR 的 key 不帶它）"""
    return s.replace("️", "")


def strip_tones(s: str) -> str:
    return "".join(ch for ch in s if ch not in TONES)


def load_annotations(src: Path, lang: str):
    names, keywords = {}, {}
    for prefix in ("ann", "der"):
        path = src / f"{prefix}-{lang}.xml"
        for a in ET.parse(path).getroot().iter("annotation"):
            cp, text = a.get("cp"), (a.text or "").strip()
            if not cp or not text or text == "↑↑↑":
                continue
            k = key(cp)
            if a.get("type") == "tts":
                names.setdefault(k, text)
            else:
                keywords.setdefault(k, [w.strip() for w in text.split("|") if w.strip()])
    return names, keywords


def clean(s: str) -> str:
    return s.replace("\t", " ").replace("\n", " ")


def main():
    src, out, symbols_out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    ann = {lang: load_annotations(src, lang) for lang in LANGS}

    base = []          # (emoji, group, version)
    tone_variants = {} # 去膚色後的 key → {膚色: 序列}
    group = None
    for line in (src / "emoji-test.txt").read_text(encoding="utf-8").splitlines():
        if line.startswith("# group:"):
            name = line.split(":", 1)[1].strip()
            group = GROUPS.index(name) if name in GROUPS else None
            continue
        if line.startswith("#") or not line.strip() or group is None:
            continue
        cps, rest = line.split(";", 1)
        if rest.split("#", 1)[0].strip() != "fully-qualified":
            continue
        emoji = "".join(chr(int(c, 16)) for c in cps.split())
        version = re.search(r"E(\d+\.\d+)", rest).group(1)
        tones = [ch for ch in emoji if ch in TONES]
        if tones:
            # 只收所有膚色一致的那個（多人組合可以各選膚色，這裡只取「統一膚色」）
            if len(set(tones)) == 1:
                tone_variants.setdefault(key(strip_tones(emoji)), {})[tones[0]] = emoji
            continue
        base.append((emoji, group, version))

    rows = []
    for emoji, group, version in base:
        variants = tone_variants.get(key(emoji), {})
        tones = " ".join(variants[t] for t in TONES) if len(variants) == 5 else ""
        cols = [emoji, str(group), version, tones]
        k = key(emoji)
        for lang in LANGS:
            names, keywords = ann[lang]
            name = names.get(k, "")
            words = [w for w in keywords.get(k, []) if w != name]
            cols += [clean(name), clean("|".join(words))]
        rows.append("\t".join(cols))

    out.write_text("\n".join(rows) + "\n", encoding="utf-8")
    print(f"wrote {len(rows)} emoji → {out}")

    # 其它字元：CLDR 有註解、但不是表情（也不是表情的膚色 / 組合序列）
    emoji_keys = {key(e) for e, _, _ in base} | {key(strip_tones(k)) for k in tone_variants}
    symbol_rows = []
    for k in sorted(ann["en"][0].keys() | ann["zh_Hant"][0].keys()):
        if k in emoji_keys or len(k) != 1:
            continue
        cols = [k]
        for lang in LANGS:
            names, keywords = ann[lang]
            name = names.get(k, "")
            words = [w for w in keywords.get(k, []) if w != name]
            cols += [clean(name), clean("|".join(words))]
        symbol_rows.append("\t".join(cols))
    symbols_out.write_text("\n".join(symbol_rows) + "\n", encoding="utf-8")
    print(f"wrote {len(symbol_rows)} symbols → {symbols_out}")


if __name__ == "__main__":
    main()
