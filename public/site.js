var site_rules = {
	'#selected_message_controls': function(el) {
		n = document.createElement('a')
		el.appendChild(n)
		n.innerHTML = 'Select All'
		n.setAttribute('href', '#')
		n.onclick = function(e) {
			document.getElementsBySelector('input.controls').each(function(e) { if(e.getAttribute('type') == 'checkbox') { e.setAttribute('checked', 'checked'); } });
		}
	}
};
Behaviour.register(site_rules);
