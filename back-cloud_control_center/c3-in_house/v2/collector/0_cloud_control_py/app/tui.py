"""
Textual TUI for Cloud Control Center
"""

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical, ScrollableContainer
from textual.widgets import Header, Footer, Static, Button, ListView, ListItem, Label, Select
from textual.reactive import reactive
from textual import on

from .config_loader import get_hosts, get_containers, get_host
from .models import Host, Container
from . import commands
from . import cloudflare
from . import exporters


CSS = """
Screen {
    layout: vertical;
}

#top-bar {
    height: 3;
    dock: top;
    background: $surface;
    padding: 0 1;
}

#top-bar Button {
    margin: 0 1;
    min-width: 8;
}

#separator {
    width: 3;
    content-align: center middle;
}

#export-select {
    width: 15;
    margin: 0 1;
}

#main-content {
    height: 1fr;
}

#left-panel {
    width: 30;
    height: 100%;
    border: solid green;
    padding: 1;
}

#right-panel {
    width: 1fr;
    height: 100%;
    border: solid blue;
    padding: 1;
}

#title-section, #title-target {
    text-style: bold;
    color: cyan;
    padding-bottom: 1;
}

#item-list {
    height: 1fr;
}

.action-btn.-active {
    background: green;
}

Button {
    margin: 0;
}

ListItem {
    padding: 0 1;
}

ListItem:hover {
    background: $surface-lighten-1;
}

#section-buttons {
    height: auto;
    layout: grid;
    grid-size: 3;
    grid-gutter: 1;
    margin-bottom: 1;
}

.section-btn {
    width: 100%;
}

.section-btn.-active {
    background: $primary;
}

#output-container {
    height: 100%;
    border: solid $primary;
}

#output-title {
    text-style: bold;
    color: yellow;
    padding: 1;
}

#output-text {
    padding: 1;
}
"""


class CloudControlCenter(App):
    """Cloud Control Center TUI Application"""

    TITLE = "Cloud Control Center"
    CSS = CSS
    BINDINGS = [
        ("q", "quit", "Quit"),
        ("1", "section_hosts", "Hosts"),
        ("2", "section_vms", "VMs"),
        ("3", "section_containers", "Containers"),
        ("r", "refresh", "Refresh"),
    ]

    current_section = reactive("hosts")
    current_action = reactive("list")
    selected_item = reactive("")

    # Cache
    _hosts = {}
    _containers = {}
    _list_counter = 0

    def on_mount(self) -> None:
        """Initialize the app"""
        self._hosts = get_hosts()
        self._containers = get_containers()
        self.update_item_list()
        self.update_action_buttons()

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="top-bar"):
            yield Button("List", id="action-list", classes="action-btn -active")
            yield Button("Start", id="action-start", classes="action-btn")
            yield Button("Stop", id="action-stop", classes="action-btn")
            yield Button("Reboot", id="action-reboot", classes="action-btn")
            yield Static(" | ", id="separator")
            yield Select(
                [("JSON", "json"), ("JSON.js", "json_js"), ("Markdown", "md"), ("CSV", "csv")],
                prompt="Export",
                id="export-select",
                allow_blank=True,
            )
        with Horizontal(id="main-content"):
            with Vertical(id="left-panel"):
                yield Static("SECTION", id="title-section")
                with Horizontal(id="section-buttons"):
                    yield Button("0.Hosts", id="btn-hosts", classes="section-btn -active")
                    yield Button("1.VMs", id="btn-vms", classes="section-btn")
                    yield Button("2.Cont", id="btn-containers", classes="section-btn")
                yield Static("SELECT TARGET", id="title-target")
                yield ListView(id="item-list")
            with Vertical(id="right-panel"):
                yield Static("OUTPUT", id="output-title")
                with ScrollableContainer(id="output-container"):
                    yield Static("Select an item and action to see output...", id="output-text")
        yield Footer()

    def update_item_list(self) -> None:
        """Update the item list based on current section"""
        list_view = self.query_one("#item-list", ListView)
        list_view.clear()
        CloudControlCenter._list_counter += 1
        n = CloudControlCenter._list_counter
        sec = self.current_section

        if sec == "hosts":
            list_view.append(ListItem(Label("CF: DNS Records"), id=f"i{n}-cf-dns"))
            list_view.append(ListItem(Label("CF: Rules"), id=f"i{n}-cf-rules"))
            list_view.append(ListItem(Label("─" * 20), id=f"i{n}-sep1"))
            for host_id, host in self._hosts.items():
                list_view.append(ListItem(Label(host.display_name), id=f"i{n}-{host_id}"))

        elif sec == "vms":
            for host_id, host in self._hosts.items():
                list_view.append(ListItem(Label(host.display_name), id=f"i{n}-{host_id}"))

        elif sec == "containers":
            for host_id in ["arch-1", "flex1", "micro1", "micro2"]:
                if host_id in self._hosts:
                    host = self._hosts[host_id]
                    list_view.append(ListItem(Label(f"── {host.display_name} ──"), id=f"i{n}-header-{host_id}"))
                    for cont_id, cont in self._containers.items():
                        if cont.host == host_id:
                            list_view.append(ListItem(Label(f"  {cont.name}"), id=f"i{n}-{cont_id}"))

    def update_action_buttons(self) -> None:
        """Update action buttons based on current section"""
        btn_list = self.query_one("#action-list", Button)
        btn_start = self.query_one("#action-start", Button)
        btn_stop = self.query_one("#action-stop", Button)
        btn_reboot = self.query_one("#action-reboot", Button)

        if self.current_section == "hosts":
            btn_list.label = "List"
            btn_start.label = "Start"
            btn_stop.label = "Stop"
            btn_reboot.label = "Reboot"
            btn_start.display = True
            btn_stop.display = True
            btn_reboot.display = True

        elif self.current_section == "vms":
            btn_list.label = "docker ps"
            btn_start.label = "top"
            btn_stop.display = False
            btn_reboot.display = False

        elif self.current_section == "containers":
            btn_list.label = "ls -la"
            btn_start.label = "ps/top"
            btn_stop.label = "stats"
            btn_stop.display = True
            btn_reboot.display = False

    def set_section(self, section: str) -> None:
        """Change the current section"""
        self.current_section = section
        self.current_action = "list"

        for btn_id, sec in [("btn-hosts", "hosts"), ("btn-vms", "vms"), ("btn-containers", "containers")]:
            btn = self.query_one(f"#{btn_id}", Button)
            if sec == section:
                btn.add_class("-active")
            else:
                btn.remove_class("-active")

        for btn_id in ["action-list", "action-start", "action-stop", "action-reboot"]:
            try:
                btn = self.query_one(f"#{btn_id}", Button)
                btn.remove_class("-active")
            except:
                pass
        self.query_one("#action-list", Button).add_class("-active")

        self.update_item_list()
        self.update_action_buttons()

    def set_action(self, action: str) -> None:
        """Change the current action"""
        self.current_action = action

        action_map = {"list": "action-list", "start": "action-start", "stop": "action-stop", "reboot": "action-reboot"}
        for act, btn_id in action_map.items():
            try:
                btn = self.query_one(f"#{btn_id}", Button)
                if act == action:
                    btn.add_class("-active")
                else:
                    btn.remove_class("-active")
            except:
                pass

    @on(Button.Pressed)
    def handle_button(self, event: Button.Pressed) -> None:
        """Handle button presses"""
        btn_id = event.button.id

        if btn_id == "btn-hosts":
            self.set_section("hosts")
        elif btn_id == "btn-vms":
            self.set_section("vms")
        elif btn_id == "btn-containers":
            self.set_section("containers")
        elif btn_id == "action-list":
            self.set_action("list")
        elif btn_id == "action-start":
            self.set_action("start")
        elif btn_id == "action-stop":
            self.set_action("stop")
        elif btn_id == "action-reboot":
            self.set_action("reboot")

    @on(Select.Changed, "#export-select")
    def handle_export(self, event: Select.Changed) -> None:
        """Handle export format selection"""
        if event.value == Select.BLANK:
            return
        output_widget = self.query_one("#output-text", Static)
        output_widget.update("Exporting...")
        self.refresh()

        try:
            if event.value == "json":
                result = exporters.export_json()
            elif event.value == "json_js":
                result = exporters.export_json_js()
            elif event.value == "md":
                result = exporters.export_markdown()
            elif event.value == "csv":
                files = exporters.export_csv()
                result = f"Exported:\n  {files['hosts']}\n  {files['containers']}"
            else:
                result = "Unknown format"
            output_widget.update(f"Exported to:\n{result}")
        except Exception as e:
            output_widget.update(f"Export error: {str(e)}")

        self.query_one("#export-select", Select).value = Select.BLANK

    @on(ListView.Selected)
    def handle_list_selection(self, event: ListView.Selected) -> None:
        """Handle list item selection"""
        item_id = event.item.id
        if not item_id or "-header-" in item_id or "-sep" in item_id:
            return

        parts = item_id.split("-", 1)
        if len(parts) < 2:
            return
        item_key = parts[1]
        self.selected_item = item_key
        self.execute_command()

    def execute_command(self) -> None:
        """Execute the selected command"""
        output_widget = self.query_one("#output-text", Static)
        output_widget.update("Executing command...")
        self.refresh()

        result = ""

        if self.current_section == "hosts":
            result = self.execute_host_command()
        elif self.current_section == "vms":
            result = self.execute_vm_command()
        elif self.current_section == "containers":
            result = self.execute_container_command()

        output_widget.update(result)

    def execute_host_command(self) -> str:
        """Execute host-related commands"""
        item = self.selected_item
        action = self.current_action

        if item == "cf-dns":
            return cloudflare.list_dns_records()
        elif item == "cf-rules":
            return cloudflare.list_rulesets()

        if item not in self._hosts:
            return f"Unknown host: {item}"

        host = self._hosts[item]

        if action == "list":
            if host.provider == "gcp":
                return commands.gcp_list()
            return commands.oci_list()
        elif action == "start":
            return commands.vm_start(host)
        elif action == "stop":
            return commands.vm_stop(host)
        elif action == "reboot":
            return commands.vm_reboot(host)

        return "Unknown action"

    def execute_vm_command(self) -> str:
        """Execute VM-related commands"""
        item = self.selected_item
        action = self.current_action

        if item not in self._hosts:
            return f"Unknown VM: {item}"

        host = self._hosts[item]

        if action == "list":
            return commands.vm_docker_ps(host)
        elif action == "start":
            return commands.vm_top(host)

        return "Unknown action"

    def execute_container_command(self) -> str:
        """Execute container-related commands"""
        item = self.selected_item
        action = self.current_action

        if item not in self._containers:
            return f"Unknown container: {item}"

        container = self._containers[item]
        host = self._hosts.get(container.host)

        if not host:
            return f"Unknown host: {container.host}"

        if action == "list":
            return commands.container_ls(host, container.name)
        elif action == "start":
            return commands.container_ps(host, container.name)
        elif action == "stop":
            return commands.container_stats(host, container.name)

        return "Unknown action"

    def action_quit(self) -> None:
        self.exit()

    def action_section_hosts(self) -> None:
        self.set_section("hosts")

    def action_section_vms(self) -> None:
        self.set_section("vms")

    def action_section_containers(self) -> None:
        self.set_section("containers")

    def action_refresh(self) -> None:
        if self.selected_item:
            self.execute_command()


def run_tui():
    """Run the TUI application."""
    app = CloudControlCenter()
    app.run()
