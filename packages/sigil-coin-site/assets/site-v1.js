document.documentElement.classList.add("js");

(() => {
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const reveals = [...document.querySelectorAll(".reveal")];

  if (reduced || !("IntersectionObserver" in window)) {
    reveals.forEach((node) => node.classList.add("is-visible"));
  } else {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        }
      });
    }, { rootMargin: "0px 0px -8%", threshold: 0.08 });
    reveals.forEach((node) => observer.observe(node));
  }

  const parallax = document.querySelector("[data-parallax]");
  if (!reduced && parallax) {
    let queued = false;
    const update = () => {
      const speed = Number(parallax.dataset.parallax) || 0;
      const offset = Math.max(-26, Math.min(26, window.scrollY * speed));
      parallax.style.transform = `translate3d(0, ${offset}px, 0)`;
      queued = false;
    };
    window.addEventListener("scroll", () => {
      if (!queued) {
        queued = true;
        window.requestAnimationFrame(update);
      }
    }, { passive: true });
  }

  const copyText = async (text) => {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return;
    }
    const field = document.createElement("textarea");
    field.value = text;
    field.setAttribute("readonly", "");
    field.style.position = "fixed";
    field.style.opacity = "0";
    document.body.appendChild(field);
    field.select();
    document.execCommand("copy");
    field.remove();
  };

  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const original = button.textContent;
      try {
        await copyText(button.dataset.copy || "");
        button.textContent = "Copied";
        button.setAttribute("aria-label", "Copied to clipboard");
      } catch (_) {
        button.textContent = "Select text";
        button.setAttribute("aria-label", "Copy failed; select the adjacent text manually");
      }
      window.setTimeout(() => {
        button.textContent = original;
      }, 1800);
    });
  });
})();
