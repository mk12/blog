// Copyright 2023 Mitchell Kember. Subject to the MIT License.

class Popover {
    constructor(sup) {
        this.sup = sup;
        this.a = sup.firstElementChild;
        this.id = this.a.getAttribute("href").slice(1);
    }

    #create() {
        this.wrapper = this.sup.appendChild(document.createElement("div"));
        this.wrapper.classList.add("fnref-wrapper");
        const content = this.wrapper.appendChild(document.createElement("div"));
        content.classList.add("fnref-content");
        const small = content.appendChild(document.createElement("small"));
        const nodes = document.getElementById(this.id).childNodes;
        for (let i = 0; i < nodes.length - 1; i++) {
            small.appendChild(nodes[i].cloneNode(true));
        }
        this.notch = this.wrapper.appendChild(document.createElement("div"));
        this.notch.classList.add("fnref-notch");
        this.notch.appendChild(document.createElement("div")).classList.add("fnref-notch-a");
        this.notch.appendChild(document.createElement("div")).classList.add("fnref-notch-b");
    }

    show() {
        if (!this.wrapper) this.#create();
        this.sup.classList.add("fnref--active");
        const root = document.documentElement;
        const sx = root.scrollLeft + document.body.scrollLeft;
        const sy = root.scrollTop + document.body.scrollTop;
        const r = this.sup.getBoundingClientRect();
        const m = 20;
        const w = Math.min(600, root.clientWidth - m * 2);
        const cx = sx + r.left + r.width / 2 - w / 2;
        const x = Math.max(m, Math.min(root.clientWidth - m - w, cx));
        const y = sy + r.bottom;
        this.wrapper.style.left = `${x}px`;
        this.wrapper.style.top = `${y}px`;
        this.wrapper.style.width = `${w}px`;
        this.wrapper.style.display = "";
        const nx = sx + r.left + r.width / 2 - 20 - x
        this.notch.style.left = `${nx}px`;
        return this;
    }

    hide() {
        this.sup.classList.remove("fnref--active");
        this.wrapper.style.display = "none";
    }
}

const all = document.querySelectorAll(".fnref");
if (!matchMedia('(hover: none)').matches) {
    for (const sup of all) {
        const popover = new Popover(sup);
        sup.addEventListener("mouseenter", () => popover.show());
        sup.addEventListener("mouseleave", () => popover.hide());
    }
} else {
    let active;
    const hideActive = () => {
        if (active) active.hide();
        active = undefined;
    }
    for (const sup of all) {
        const popover = new Popover(sup);
        popover.a.addEventListener("click", e => {
            e.preventDefault();
            const show = active !== popover;
            hideActive();
            if (show) active = popover.show();
        });
        sup.addEventListener("click", e => e.stopPropagation());
        document.addEventListener("click", hideActive);
    }
}
