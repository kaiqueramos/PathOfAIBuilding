(() => {
  "use strict";

  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const header = document.querySelector("[data-header]");
  const nav = document.querySelector("[data-nav]");
  const navToggle = document.querySelector("[data-nav-toggle]");
  const navLinks = nav ? [...nav.querySelectorAll('a[href^="#"]')] : [];

  const syncHeader = () => {
    header?.classList.toggle("is-scrolled", window.scrollY > 18);
  };

  const closeNav = () => {
    if (!nav || !navToggle) return;
    nav.classList.remove("is-open");
    navToggle.setAttribute("aria-expanded", "false");
    document.body.classList.remove("nav-open");
  };

  const openNav = () => {
    if (!nav || !navToggle) return;
    nav.classList.add("is-open");
    navToggle.setAttribute("aria-expanded", "true");
    document.body.classList.add("nav-open");
  };

  navToggle?.addEventListener("click", () => {
    if (navToggle.getAttribute("aria-expanded") === "true") closeNav();
    else openNav();
  });

  navLinks.forEach((link) => link.addEventListener("click", closeNav));

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeNav();
  });

  window.addEventListener("resize", () => {
    if (window.innerWidth > 920) closeNav();
  });

  window.addEventListener("scroll", syncHeader, { passive: true });
  syncHeader();

  const revealItems = [...document.querySelectorAll(".reveal")];
  if (reducedMotion || !("IntersectionObserver" in window)) {
    revealItems.forEach((item) => item.classList.add("is-visible"));
  } else {
    const revealObserver = new IntersectionObserver(
      (entries, observer) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        });
      },
      { rootMargin: "0px 0px -8%", threshold: 0.08 },
    );
    revealItems.forEach((item) => revealObserver.observe(item));
  }

  if ("IntersectionObserver" in window && navLinks.length) {
    const sections = navLinks
      .map((link) => document.querySelector(link.getAttribute("href")))
      .filter(Boolean);

    const sectionObserver = new IntersectionObserver(
      (entries) => {
        const visible = entries
          .filter((entry) => entry.isIntersecting)
          .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
        if (!visible) return;
        navLinks.forEach((link) => {
          link.classList.toggle("is-current", link.getAttribute("href") === `#${visible.target.id}`);
        });
      },
      { rootMargin: "-28% 0px -62%", threshold: [0, 0.15, 0.5] },
    );

    sections.forEach((section) => sectionObserver.observe(section));
  }

  const demoTabs = [...document.querySelectorAll("[data-scenario]")];
  const copy = document.documentElement.lang.startsWith("en")
    ? {
        upgrade: {
          question: "What is my best next upgrade without losing survivability?",
          answer: "I found a support swap that increases damage without reducing EHP. I tested it in an isolated clone and recalculated the build.",
          stats: ["+15.4%", "+2.1%", "+3.8%"],
          labels: ["DPS", "EHP", "Max hit"],
          type: "replace support",
          action: "Replace the main skill support",
        },
        defense: {
          question: "Why does this build struggle against physical damage?",
          answer: "Physical max hit is the main gap. I simulated a defensive configuration that raises it with almost no DPS loss.",
          stats: ["+18.7%", "+11.2%", "-0.6%"],
          labels: ["Phys. max hit", "EHP", "DPS"],
          type: "change config",
          action: "Enable Granite Flask and Molten Shell",
        },
        gems: {
          question: "Which support gem gives this setup the best gain?",
          answer: "I tested compatible supports in the PoB engine and ranked the options by their calculated impact.",
          stats: ["+12.8%", "+0.0%", "+0.0%"],
          labels: ["DPS", "EHP", "Max hit"],
          type: "replace support",
          action: "Use the highest-gain compatible support",
        },
      }
    : {
        upgrade: {
          question: "Qual é o melhor próximo upgrade sem perder sobrevivência?",
          answer: "Encontrei uma troca de suporte que aumenta o dano sem reduzir o EHP. Testei a mudança em um clone isolado e recalculei o build.",
          stats: ["+15,4%", "+2,1%", "+3,8%"],
          labels: ["DPS", "EHP", "Max hit"],
          type: "replace support",
          action: "Trocar suporte da skill principal",
        },
        defense: {
          question: "Por que esta build sofre contra dano físico?",
          answer: "O max hit físico é a principal lacuna. Simulei uma configuração defensiva que o aumenta com perda mínima de DPS.",
          stats: ["+18,7%", "+11,2%", "-0,6%"],
          labels: ["Max hit físico", "EHP", "DPS"],
          type: "change config",
          action: "Ativar Granite Flask e Molten Shell",
        },
        gems: {
          question: "Qual gema de suporte entrega o maior ganho aqui?",
          answer: "Testei os suportes compatíveis no motor do PoB e ordenei as opções pelo impacto calculado.",
          stats: ["+12,8%", "+0,0%", "+0,0%"],
          labels: ["DPS", "EHP", "Max hit"],
          type: "replace support",
          action: "Usar o suporte compatível de maior ganho",
        },
      };

  const renderScenario = (tab) => {
    const scenario = copy[tab.dataset.scenario];
    if (!scenario) return;
    demoTabs.forEach((item) => {
      const active = item === tab;
      item.classList.toggle("is-active", active);
      item.setAttribute("aria-selected", String(active));
      item.tabIndex = active ? 0 : -1;
    });
    const values = {
      "[data-demo-question]": scenario.question,
      "[data-demo-answer]": scenario.answer,
      "[data-demo-stat-one]": scenario.stats[0],
      "[data-demo-stat-two]": scenario.stats[1],
      "[data-demo-stat-three]": scenario.stats[2],
      "[data-demo-label-two]": scenario.labels[1],
      "[data-demo-label-three]": scenario.labels[2],
      "[data-demo-action-type]": scenario.type,
      "[data-demo-action]": scenario.action,
    };
    Object.entries(values).forEach(([selector, value]) => {
      const element = document.querySelector(selector);
      if (element) element.textContent = value;
    });
    const firstLabel = document.querySelector(".diff-grid > div:first-child span");
    if (firstLabel) firstLabel.textContent = scenario.labels[0];
  };

  demoTabs.forEach((tab, index) => {
    tab.addEventListener("click", () => renderScenario(tab));
    tab.addEventListener("keydown", (event) => {
      if (!["ArrowLeft", "ArrowRight"].includes(event.key)) return;
      event.preventDefault();
      const direction = event.key === "ArrowRight" ? 1 : -1;
      const next = demoTabs[(index + direction + demoTabs.length) % demoTabs.length];
      renderScenario(next);
      next.focus();
    });
  });
  if (demoTabs[0]) renderScenario(demoTabs[0]);

  const setupSteps = [...document.querySelectorAll("[data-setup-step]")];
  const setupPanels = [...document.querySelectorAll("[data-setup-panel]")];
  setupSteps.forEach((step) => {
    const button = step.querySelector("button");
    button?.addEventListener("click", () => {
      const name = step.dataset.setupStep;
      setupSteps.forEach((item) => {
        const active = item === step;
        item.classList.toggle("is-active", active);
        item.querySelector("button")?.setAttribute("aria-expanded", String(active));
      });
      setupPanels.forEach((panel) => {
        panel.hidden = panel.dataset.setupPanel !== name;
      });
    });
  });

  const faqItems = [...document.querySelectorAll("[data-faq] .faq-item")];
  faqItems.forEach((item) => {
    const button = item.querySelector("button");
    button?.addEventListener("click", () => {
      const willOpen = !item.classList.contains("is-open");
      faqItems.forEach((other) => {
        other.classList.remove("is-open");
        other.querySelector("button")?.setAttribute("aria-expanded", "false");
      });
      if (willOpen) {
        item.classList.add("is-open");
        button.setAttribute("aria-expanded", "true");
      }
    });
  });

  const year = document.querySelector("[data-year]");
  if (year) year.textContent = String(new Date().getFullYear());
})();
