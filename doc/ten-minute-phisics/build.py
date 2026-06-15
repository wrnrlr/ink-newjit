#!/usr/bin/env python3
"""Build Ten Minute Physics chapter notes from transcripts, PDFs, and source code."""

import io
import os
import re
import time
import urllib.request
import tempfile

from youtube_transcript_api import YouTubeTranscriptApi
from pdfminer.high_level import extract_text as pdf_extract_text

OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_GH = "https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/"
PDF_BASE = "https://matthias-research.github.io/pages/tenMinutePhysics/"

CHAPTERS = [
    {
        "num": 1, "slug": "intro",
        "title": "Introduction to 2D Web Browser Physics",
        "video_id": "oPuSvdBGrpE",
        "codes": ["01-cannonball2d.html"],
        "pdf": None,
    },
    {
        "num": 2, "slug": "intro-3d",
        "title": "Introduction to 3D and VR Web Browser Physics",
        "video_id": "j84zJ06wnVA",
        "codes": ["02-cannonball3d.html", "02-cannonballVR.html"],
        "pdf": None,
    },
    {
        "num": 3, "slug": "ball-collision",
        "title": "Ball Collision Handling in 2D",
        "video_id": "ThhdlMbGT5g",
        "codes": ["03-billiard.html"],
        "pdf": None,
    },
    {
        "num": 4, "slug": "pinball",
        "title": "How to Write a Pinball Simulation",
        "video_id": "NhVUCsXp-Uo",
        "codes": ["04-pinball.html"],
        "pdf": None,
    },
    {
        "num": 5, "slug": "position-based",
        "title": "The Simplest Possible Physics Simulation Method",
        "video_id": "qISgdDhdCro",
        "codes": ["05-bead.html", "05-manyBeads.html"],
        "pdf": None,
    },
    {
        "num": 6, "slug": "pendulum",
        "title": "Writing a Triple Pendulum Simulation is Simple",
        "video_id": "XPZEeS70zzU",
        "codes": ["06-pendulumShort.html", "06-pendulum.html"],
        "pdf": None,
    },
    {
        "num": 7, "slug": "3d-math",
        "title": "Intuitive 3D Vector Math for Simulation",
        "video_id": "hRz3sh7QQ6w",
        "codes": [],
        "pdf": "07-3dmath.pdf",
    },
    {
        "num": 8, "slug": "interaction",
        "title": "Providing User Interaction with a 3D Scene",
        "video_id": "iH_UgUb-LYM",
        "codes": ["08-interaction.html"],
        "pdf": None,
    },
    {
        "num": 9, "slug": "xpbd",
        "title": "Getting Ready to Simulate the World with XPBD",
        "video_id": "jrociOAYqxA",
        "codes": [],
        "pdf": "09-xpbd.pdf",
    },
    {
        "num": 10, "slug": "soft-bodies",
        "title": "Simple and Unbreakable Simulation of Soft Bodies",
        "video_id": "uCaHXkS2cUg",
        "codes": ["10-softBodies.html"],
        "pdf": "10-softBodies.pdf",
    },
    {
        "num": 11, "slug": "hashing",
        "title": "Finding Overlaps Among Thousands of Objects Blazing Fast",
        "video_id": "D2M8jTtKi44",
        "codes": ["11-hashing.html"],
        "pdf": "11-hashing.pdf",
    },
    {
        "num": 12, "slug": "soft-body-skinning",
        "title": "100x Speedup for Soft Body Simulations",
        "video_id": "Noo5sfGGWe0",
        "codes": ["12-softBodySkinning.html"],
        "pdf": "12-softBodySkinning.pdf",
    },
    {
        "num": 13, "slug": "tetrahedralize",
        "title": "Writing a Tetrahedralizer for Blender",
        "video_id": "sNxz_Ht6Y1Y",
        "codes": ["BlenderTetPlugin.py"],
        "pdf": "13-Tetrahedralize.pdf",
    },
    {
        "num": 14, "slug": "cloth",
        "title": "The Secret of Cloth Simulation",
        "video_id": "z5oWopN39OU",
        "codes": ["14-cloth.html"],
        "pdf": "14-cloth.pdf",
    },
    {
        "num": 15, "slug": "self-collision",
        "title": "Self-Collisions: Solving the Hardest Problem in Animation",
        "video_id": "XY3dLpgOk4Q",
        "codes": ["15-selfCollision.html"],
        "pdf": "15-selfCollision.pdf",
    },
    {
        "num": 16, "slug": "gpu",
        "title": "Simulation on the GPU",
        "video_id": "q4rNoupGr8U",
        "codes": ["16-GPUCloth.py"],
        "pdf": "16-GPUSimulation.pdf",
    },
    {
        "num": 17, "slug": "eulerian-fluid",
        "title": "How to Write an Eulerian Fluid Simulator with 200 Lines of Code",
        "video_id": "iKAVRgIrUOU",
        "codes": ["17-fluidSim.html"],
        "pdf": "17-fluidSim.pdf",
    },
    {
        "num": 18, "slug": "flip-water",
        "title": "How to Write a FLIP Water Simulator",
        "video_id": "XmzBREkK8kY",
        "codes": ["18-flip.html"],
        "pdf": "18-flip.pdf",
    },
    {
        "num": 19, "slug": "ode",
        "title": "Differential Equations and Calculus from Scratch",
        "video_id": "asiFbvRKgRk",
        "codes": ["19-julia.html"],
        "pdf": "19-ODE.pdf",
    },
    {
        "num": 20, "slug": "height-field-water",
        "title": "How to Write a Height-Field Water Simulation",
        "video_id": "hswBi5wcqAA",
        "codes": ["20-heightFieldWater.html"],
        "pdf": "20-heightFieldWater.pdf",
    },
    {
        "num": 21, "slug": "fire",
        "title": "How to Write a Fire Simulator in a Web Page",
        "video_id": "RsgmS3ZxDtc",
        "codes": ["21-fire.html"],
        "pdf": "21-fire.pdf",
    },
    {
        "num": 22, "slug": "rigid-bodies",
        "title": "How to Write a Basic Rigid Body Simulator Using Position Based Dynamics",
        "video_id": "euypZDssYxE",
        "codes": ["22-rigidBodies.html"],
        "pdf": "22-rigidBodies.pdf",
    },
    {
        "num": 23, "slug": "sweep-and-prune",
        "title": "Broad Phase Collision Detection with Sweep and Prune",
        "video_id": "MKeWXBgEGxQ",
        "codes": ["23-SAP.html"],
        "pdf": "23-SAP.pdf",
    },
    {
        "num": 24, "slug": "bvh",
        "title": "Bounding Volume Hierarchies with a Blazing Fast Implementation",
        "video_id": "LAxHQZ8RjQ4",
        "codes": ["24-morton.html"],
        "pdf": "24-morton.pdf",
    },
    {
        "num": 25, "slug": "joints",
        "title": "Joint Simulation Made Simple",
        "video_id": "YVaQxeWGlJA",
        "codes": ["25-joints.html"],
        "pdf": "25-joints.pdf",
    },
]


def get_transcript(video_id: str) -> str:
    try:
        api = YouTubeTranscriptApi()
        snippets = api.fetch(video_id)
        # Join snippets into paragraphs, cleaning up mid-word line breaks
        texts = []
        for s in snippets:
            texts.append(s.text.replace("\n", " "))
        raw = " ".join(texts)
        # Clean up common artifacts
        raw = re.sub(r"\[Music\]", "", raw, flags=re.IGNORECASE)
        raw = re.sub(r"\[Applause\]", "", raw, flags=re.IGNORECASE)
        raw = re.sub(r" +", " ", raw).strip()
        # Simple sentence wrapping: split on ". " boundaries
        sentences = re.split(r'(?<=[.!?])\s+', raw)
        # Group into paragraphs of ~5 sentences
        paras = []
        chunk = []
        for i, s in enumerate(sentences):
            chunk.append(s)
            if len(chunk) == 5:
                paras.append(" ".join(chunk))
                chunk = []
        if chunk:
            paras.append(" ".join(chunk))
        return "\n\n".join(paras)
    except Exception as e:
        return f"[Transcript unavailable: {e}]"


def fetch_url(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def get_pdf_text(pdf_name: str) -> str:
    url = PDF_BASE + pdf_name
    try:
        data = fetch_url(url)
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(data)
            tmp = f.name
        text = pdf_extract_text(tmp)
        os.unlink(tmp)
        # Clean up extracted text
        text = re.sub(r'\n{3,}', '\n\n', text)
        text = text.strip()
        return text
    except Exception as e:
        return f"[Slides unavailable: {e}]"


def get_code(filename: str) -> tuple[str, str]:
    url = RAW_GH + filename
    try:
        code = fetch_url(url).decode("utf-8", errors="replace")
        ext = filename.rsplit(".", 1)[-1]
        lang = {"html": "html", "py": "python", "js": "javascript"}.get(ext, ext)
        return filename, f"```{lang}\n{code}\n```"
    except Exception as e:
        return filename, f"[Code unavailable: {e}]"


def build_chapter(ch: dict) -> str:
    num = ch["num"]
    print(f"  [{num:02d}] transcript...", end=" ", flush=True)
    transcript = get_transcript(ch["video_id"])
    print("done", flush=True)

    pdf_text = ""
    if ch["pdf"]:
        print(f"  [{num:02d}] pdf...", end=" ", flush=True)
        pdf_text = get_pdf_text(ch["pdf"])
        print("done", flush=True)

    code_blocks = []
    for cfile in ch["codes"]:
        print(f"  [{num:02d}] code {cfile}...", end=" ", flush=True)
        fname, block = get_code(cfile)
        code_blocks.append((fname, block))
        print("done", flush=True)
        time.sleep(0.2)

    # Assemble markdown
    lines = []
    lines.append(f"# Chapter {num:02d} — {ch['title']}")
    lines.append("")
    lines.append(f"**Video:** https://youtu.be/{ch['video_id']}")
    if ch["pdf"]:
        lines.append(f"**Slides:** {PDF_BASE}{ch['pdf']}")
    for cfile in ch["codes"]:
        lines.append(f"**Code:** {RAW_GH}{cfile}")
    lines.append("")

    # Lecture notes from PDF
    if pdf_text and not pdf_text.startswith("[Slides unavailable"):
        lines.append("## Lecture Notes")
        lines.append("")
        lines.append(pdf_text)
        lines.append("")

    # Video transcript
    lines.append("## Video Transcript")
    lines.append("")
    lines.append(transcript)
    lines.append("")

    # Source code
    if code_blocks:
        lines.append("## Source Code")
        lines.append("")
        for fname, block in code_blocks:
            lines.append(f"### {fname}")
            lines.append("")
            lines.append(block)
            lines.append("")

    return "\n".join(lines)


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    for ch in CHAPTERS:
        filename = f"ch{ch['num']:02d}-{ch['slug']}.md"
        out_path = os.path.join(OUTPUT_DIR, filename)
        print(f"Processing chapter {ch['num']:02d}: {ch['title']}")
        content = build_chapter(ch)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"  -> wrote {filename}")
        time.sleep(0.5)  # be polite
    print("\nAll done.")


if __name__ == "__main__":
    main()
