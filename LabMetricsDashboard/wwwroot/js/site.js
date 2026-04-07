(() => {
    const activeTabInput = document.getElementById("activeTabInput");
    const tabButtons = document.querySelectorAll('#dashboardTabs button[data-bs-toggle="pill"]');

    tabButtons.forEach((button) => {
        button.addEventListener("shown.bs.tab", (event) => {
            const target = event.target.getAttribute("data-bs-target");
            if (target && activeTabInput) {
                activeTabInput.value = target.replace("#", "");
            }
        });
    });

    document.querySelectorAll(".table-search-input").forEach((input) => {
        input.addEventListener("input", () => {
            const tableId = input.getAttribute("data-target-table");
            const table = document.getElementById(tableId);
            if (!table) {
                return;
            }

            const searchText = input.value.trim().toLowerCase();
            const rows = table.querySelectorAll("tbody tr");
            rows.forEach((row) => {
                const text = row.innerText.toLowerCase();
                row.style.display = text.includes(searchText) ? "" : "none";
            });
        });
    });

    document.querySelectorAll(".accordion-search-input").forEach((input) => {
        input.addEventListener("input", () => {
            const accordionId = input.getAttribute("data-target-accordion");
            const accordion = document.getElementById(accordionId);
            if (!accordion) {
                return;
            }

            const searchText = input.value.trim().toLowerCase();
            const items = accordion.querySelectorAll(".claim-group-item");

            items.forEach((item) => {
                const text = item.innerText.toLowerCase();
                item.style.display = text.includes(searchText) ? "" : "none";
            });
        });
    });

    const charts = window.dashboardCharts;
    if (charts && typeof Chart !== "undefined") {
        const defaultPalette = [
            "rgba(27, 42, 74, 0.85)",
            "rgba(46, 95, 163, 0.85)",
            "rgba(25, 135, 84, 0.85)",
            "rgba(245, 159, 0, 0.85)",
            "rgba(220, 53, 69, 0.85)",
            "rgba(142, 68, 173, 0.85)",
            "rgba(13, 202, 240, 0.85)"
        ];

        const buildChart = (canvasId, type, dataObject) => {
            const canvas = document.getElementById(canvasId);
            if (!canvas || !dataObject) {
                return;
            }

            const labels = Object.keys(dataObject);
            const values = Object.values(dataObject);

            new Chart(canvas, {
                type,
                data: {
                    labels,
                    datasets: [{
                        data: values,
                        backgroundColor: defaultPalette,
                        borderWidth: 0,
                        borderRadius: type === "bar" ? 10 : 0
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        legend: {
                            display: type !== "bar",
                            position: "bottom"
                        }
                    },
                    scales: type === "bar"
                        ? {
                            x: {
                                grid: { display: false }
                            },
                            y: {
                                beginAtZero: true,
                                ticks: { precision: 0 }
                            }
                        }
                        : {}
                }
            });
        };

        buildChart("statusChart", "bar", charts.status);
        buildChart("priorityChart", "doughnut", charts.priority);
    }
})();
