// parses https://topper64.co.uk/nk/btd6/rounds/regular and https://topper64.co.uk/nk/btd6/rounds/alternate

var out = '&.{\n';

var rounds = document.getElementsByClassName('round');
Array.from(rounds).map(function(round, n) {
	out += `\t.{\n\t\t.id = ${n+1},\n\t\t.waves = &.{\n`;

	var imgs = round.getElementsByClassName('bloon');
	var waves = Array.from(imgs).map(img => img.parentElement);
	var names = waves.map(wave => wave.className);
	var counts = waves.map(wave => wave.getElementsByClassName('count').item(0).textContent);
	var timestamps = waves.map(wave => wave.getElementsByClassName('timeline').item(0).children.item(1).textContent);

	names.map(function(name, i) {
		out += '\t\t\t.{\n';

		var timestamp = timestamps[i];
		var start_end = timestamp.substring(0, timestamp.length-1).split('s – ');
		var start = start_end[0];
		var end = start_end[1];

		out += `\t\t\t\t.start = ${start},\n\t\t\t\t.end = ${end},\n`;

		var count = counts[i];
		out += `\t\t\t\t.count = ${count},\n`;

		var attrs = name.split(' ');
		var goon = attrs[attrs.length-1];
		var template_fn = ''
		if (   (goon.localeCompare('red') === 0)
			|| (goon.localeCompare('blue') === 0)
			|| (goon.localeCompare('green') === 0)
			|| (goon.localeCompare('yellow') === 0)
			|| (goon.localeCompare('pink') === 0)
		) {
			template_fn = 'normal';
		} else {
			template_fn = 'special';
			if ((n >= 80) && (goon.localeCompare('ceramic') === 0)) {
				goon = 'super_ceramic';
			}
		}

		var extra = '.{';
		if (goon.localeCompare('ddt') === 0) {
			extra += '\n\t\t\t\t\t.camo = true,\n\t\t\t\t\t.regrow = true,\n\t\t\t\t';
		} else if (attrs.length > 2) {
			extra += '\n';
			for (let a of Array(attrs.length-2).keys()) {
				if (attrs[a+1].localeCompare('camo') === 0) {
					extra += '\t\t\t\t\t.camo = true,\n';
				} else if (attrs[a+1].localeCompare('fortified') === 0) {
					extra += '\t\t\t\t\t.fortified = true,\n';
				} else if (attrs[a+1].localeCompare('regrow') === 0) {
					extra += '\t\t\t\t\t.regrow = true,\n';
				}
			}
			extra += '\t\t\t\t';
		}
		extra += '}';

		out += `\t\t\t\t.goon_template = Template.${template_fn}(.${goon}, ${extra}),\n`;

		out += '\t\t\t},\n';
	});
	out += '\t\t},\n\t},\n'
})

out += '};\n'
console.log(out);
