"""Natural ordering: img2 < img10, deterministic across machines."""

from __future__ import annotations

from telegram_bulk_image_sender.ordering import natural_key


def test_digits_compare_numerically() -> None:
    names = ["img10.jpg", "img2.jpg", "img1.jpg"]
    assert sorted(names, key=natural_key) == ["img1.jpg", "img2.jpg", "img10.jpg"]


def test_multi_digit_runs_and_text_mixed() -> None:
    names = ["photo-2-b", "photo-10-a", "photo-10-b", "photo-1"]
    assert sorted(names, key=natural_key) == [
        "photo-1",
        "photo-2-b",
        "photo-10-a",
        "photo-10-b",
    ]


def test_case_insensitive_with_raw_tiebreak() -> None:
    # IMG2 and img2 compare equal casefolded; raw string breaks the tie.
    keyed = sorted(["img2.jpg", "IMG2.jpg", "img10.jpg"], key=natural_key)
    assert keyed == ["IMG2.jpg", "img2.jpg", "img10.jpg"]


def test_leading_zeros_deterministic() -> None:
    # img02 vs img2 are numerically equal; the raw-name tiebreak gives a
    # total order, independent of input order (cross-machine determinism).
    assert sorted(["img2.jpg", "img02.jpg"], key=natural_key) == ["img02.jpg", "img2.jpg"]
    assert sorted(["img02.jpg", "img2.jpg"], key=natural_key) == ["img02.jpg", "img2.jpg"]


def test_total_order_over_unicode() -> None:
    names = ["IMG_9823.jpg", "IMG_982.jpg", "café.jpg", "cafe.jpg"]
    ordered = sorted(names, key=natural_key)
    assert ordered == ["cafe.jpg", "café.jpg", "IMG_982.jpg", "IMG_9823.jpg"]
