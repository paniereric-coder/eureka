const { chromium } = require("playwright");

(async () => {

    const browser = await chromium.launch({
        headless: false
    });

    const context = await browser.newContext();

    //
    // IMPORTANT :
    // écoute au niveau du CONTEXT,
    // donc également les requêtes qui créent un popup.
    //
    context.on("request", request => {

        const url = request.url();

        // On ne garde que Varennes et Eureka.
        if (
            !url.includes("ville.varennes.qc.ca") &&
            !url.includes("eureka.cc")
        ) {
            return;
        }

        //
        // On ignore les ressources sans intérêt.
        //
        if (
            /\.(css|js|png|jpg|jpeg|gif|svg|woff|woff2)(\?|$)/i.test(url)
        ) {
            return;
        }

        console.log("\n============= REQUEST =============");
        console.log("METHOD :", request.method());
        console.log("TYPE   :", request.resourceType());
        console.log("URL    :", url);

        const headers = request.headers();

        if (headers.referer) {
            console.log("REFERER:", headers.referer);
        }

        const data = request.postData();

        if (data) {
            const sanitized = data
                .replace(
                    /"username"\s*:\s*"[^"]*"/gi,
                    '"username":"<USERNAME>"'
                )
                .replace(
                    /"password"\s*:\s*"[^"]*"/gi,
                    '"password":"<PASSWORD>"'
                );

            console.log("DATA   :", sanitized);
        }
    });


    context.on("response", async response => {

        const url = response.url();

        if (
            !url.includes("ville.varennes.qc.ca") &&
            !url.includes("eureka.cc")
        ) {
            return;
        }

        if (
            /\.(css|js|png|jpg|jpeg|gif|svg|woff|woff2)(\?|$)/i.test(url)
        ) {
            return;
        }

        const status = response.status();

        console.log(
            "RESPONSE:",
            status,
            url
        );

        //
        // Les 301/302 sont particulièrement intéressants.
        //
        if (status >= 300 && status < 400) {
            const headers = response.headers();

            if (headers.location) {
                console.log(
                    "LOCATION:",
                    headers.location
                );
            }
        }
    });


    context.on("page", async page => {

        console.log(
            "\n******** NOUVEL ONGLET ********"
        );

        try {
            console.log("URL :", page.url());
        }
        catch {
        }
    });


    const page = await context.newPage();

    await page.goto(
        "https://biblio.ville.varennes.qc.ca/account",
        {
            waitUntil: "domcontentloaded"
        }
    );


    //
    // BONUS :
    // lorsqu'un lien Eureka apparaît,
    // essayer d'afficher son href AVANT le clic.
    //
    setInterval(async () => {
        try {
            const links = await page.locator("a").evaluateAll(
                elements =>
                    elements
                        .map(a => ({
                            text: (a.innerText || "").trim(),
                            href: a.href
                        }))
                        .filter(
                            x =>
                                /eureka/i.test(x.text) ||
                                /eureka/i.test(x.href)
                        )
            );

            if (links.length) {
                console.log(
                    "\n===== LIENS EUREKA TROUVES ====="
                );

                for (const link of links) {
                    console.log(link);
                }
            }
        }
        catch {
        }
    }, 3000);


    console.log("");
    console.log("1. Connecte-toi.");
    console.log("2. Va jusqu'au lien Eureka.");
    console.log("3. Clique dessus.");
    console.log("");

    await new Promise(() => {});

})();