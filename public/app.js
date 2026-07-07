// Theme toggle (persisted), active-heading highlighting, mobile nav.

(function () {
  const saved = localStorage.getItem("ink-theme");
  const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  document.documentElement.setAttribute("data-theme", saved || (prefersDark ? "dark" : "light"));
})();

function toggleTheme() {
  const cur = document.documentElement.getAttribute("data-theme");
  const next = cur === "dark" ? "light" : "dark";
  document.documentElement.setAttribute("data-theme", next);
  localStorage.setItem("ink-theme", next);
}

document.addEventListener("DOMContentLoaded", function () {
  // Highlight the TOC entry for the heading currently in view.
  const toc = document.querySelector(".toc");
  if (toc) {
    const links = new Map();
    toc.querySelectorAll("a").forEach((a) => links.set(a.getAttribute("href").slice(1), a));
    const heads = [...links.keys()]
      .map((id) => document.getElementById(id))
      .filter(Boolean);
    if (heads.length) {
      const obs = new IntersectionObserver(
        (entries) => {
          entries.forEach((e) => {
            if (e.isIntersecting) {
              links.forEach((a) => a.classList.remove("active"));
              const a = links.get(e.target.id);
              if (a) a.classList.add("active");
            }
          });
        },
        { rootMargin: "-80px 0px -70% 0px", threshold: 0 }
      );
      heads.forEach((h) => obs.observe(h));
    }
  }

  // Close the mobile nav after tapping a link.
  document.querySelectorAll(".sidebar a").forEach((a) =>
    a.addEventListener("click", () => document.body.classList.remove("nav-open"))
  );
});
