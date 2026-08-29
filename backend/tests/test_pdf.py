"""PDF operations and page-range parsing, exercised without the API layer."""

from __future__ import annotations

from pathlib import Path

import pymupdf
import pytest

from app.core.errors import InvalidPdfError
from app.services.pdf import operations, ranges


@pytest.fixture
def make_pdf(tmp_path: Path):
    def _make(name: str, pages: int = 3) -> Path:
        path = tmp_path / name
        doc = pymupdf.open()
        for index in range(pages):
            page = doc.new_page()
            page.insert_text(pymupdf.Point(72, 72), f"Page {index + 1}")
        doc.save(path)
        doc.close()
        return path

    return _make


def test_inspect_reports_page_count(make_pdf):
    assert operations.inspect(make_pdf("a.pdf", pages=4)).page_count == 4


def test_inspect_rejects_a_non_pdf(tmp_path: Path):
    path = tmp_path / "not.pdf"
    path.write_bytes(b"definitely not a pdf")

    with pytest.raises(InvalidPdfError):
        operations.inspect(path)


def test_inspect_rejects_an_encrypted_pdf(tmp_path: Path, make_pdf):
    source = make_pdf("plain.pdf")
    locked = tmp_path / "locked.pdf"
    with pymupdf.open(source) as doc:
        doc.save(
            locked,
            encryption=pymupdf.PDF_ENCRYPT_AES_256,
            owner_pw="owner",
            user_pw="user",
        )

    with pytest.raises(InvalidPdfError, match="password"):
        operations.inspect(locked)


def test_merge_concatenates_pages(make_pdf, tmp_path: Path):
    destination = tmp_path / "merged.pdf"
    operations.merge([make_pdf("a.pdf", 2), make_pdf("b.pdf", 3)], destination)

    assert operations.inspect(destination).page_count == 5


def test_merge_needs_two_files(make_pdf, tmp_path: Path):
    with pytest.raises(InvalidPdfError):
        operations.merge([make_pdf("a.pdf")], tmp_path / "out.pdf")


def test_extract_pages_keeps_the_requested_order(make_pdf, tmp_path: Path):
    source = make_pdf("a.pdf", pages=5)
    destination = tmp_path / "out.pdf"
    operations.extract_pages(source, destination, pages=[3, 1])

    with pymupdf.open(destination) as doc:
        assert doc.page_count == 2
        assert "Page 3" in doc[0].get_text()
        assert "Page 1" in doc[1].get_text()


def test_split_to_zip_bundles_one_file_per_range(make_pdf, tmp_path: Path):
    import zipfile

    source = make_pdf("a.pdf", pages=6)
    destination = tmp_path / "out.zip"
    parts = [tmp_path / "p1.pdf", tmp_path / "p2.pdf"]

    operations.split_to_zip(
        source, destination, ranges=[[1, 2], [5, 6]], part_paths=parts
    )

    with zipfile.ZipFile(destination) as archive:
        assert archive.namelist() == ["part-1.pdf", "part-2.pdf"]


def test_add_text_writes_onto_the_page(make_pdf, tmp_path: Path):
    source = make_pdf("a.pdf")
    destination = tmp_path / "out.pdf"
    operations.add_text(
        source, destination, page_number=2, text="Approved", x=100, y=100
    )

    with pymupdf.open(destination) as doc:
        assert "Approved" in doc[1].get_text()


def test_add_text_rejects_a_page_past_the_end(make_pdf, tmp_path: Path):
    with pytest.raises(InvalidPdfError):
        operations.add_text(
            make_pdf("a.pdf", pages=2),
            tmp_path / "out.pdf",
            page_number=9,
            text="x",
            x=10,
            y=10,
        )


def test_compress_produces_a_readable_pdf(make_pdf, tmp_path: Path):
    destination = tmp_path / "out.pdf"
    operations.compress(make_pdf("a.pdf", pages=3), destination)

    assert operations.inspect(destination).page_count == 3


@pytest.mark.parametrize(
    ("spec", "expected"),
    [
        ("1-3", [[1, 2, 3]]),
        ("1-3,7", [[1, 2, 3], [7]]),
        (" 2 , 4 ", [[2], [4]]),
        ("5-3", [[5, 4, 3]]),
    ],
)
def test_parse_ranges(spec, expected):
    assert ranges.parse_ranges(spec, page_count=10) == expected


@pytest.mark.parametrize("spec", ["", "0", "11", "abc", "1-", "1--2"])
def test_parse_ranges_rejects_bad_input(spec):
    with pytest.raises(InvalidPdfError):
        ranges.parse_ranges(spec, page_count=10)
