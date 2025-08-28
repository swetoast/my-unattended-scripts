# dupe_finder.sh

`dupe_finder.sh` is a command‑line tool for detecting duplicate or near‑duplicate files using three different modes:

- **exact** — Byte‑for‑byte SHA‑256 hashing for perfect matches  
- **phash** — Perceptual hashing for similar‑looking images  
- **fuzzytext** — Fuzzy text matching for ~90%‑similar documents

---

## Requirements

- **Common utilities**: `bash`, `sha256sum`, `sqlite3`
- **Mode‑specific**:  
  - `phash` → perceptual hash CLI (`pHash`)  
  - `fuzzytext` → `simhash`, `pdftotext`, `docx2txt`

Make sure these are installed before running.

---

## Usage

```bash
# Exact byte‑for‑byte hashing
./dupe_finder.sh --mode exact --dir /path/to/scan

# Perceptual hashing for images
./dupe_finder.sh --mode phash --dir /path/to/images

# Fuzzy text matching for documents
./dupe_finder.sh --mode fuzzytext --dir /path/to/docs

# Perceptual hashing with custom similarity threshold
# Lower threshold = stricter match, higher = more tolerant
./dupe_finder.sh --mode phash --dir /path/to/images --threshold 3
