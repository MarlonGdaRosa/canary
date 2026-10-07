const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const runtime = process.env.CANARYAAC_TEST_ROOT || 'C:/Users/Marlon/Documents/OT/.tools/canaryaac';
const elements = new Map();
const document = {getElementById(id) {
    if (!elements.has(id)) elements.set(id, {value:'', style:{}, classList:{add(){},remove(){},toggle(){}},
        addEventListener(name, callback){ this[name] = callback; }, setCustomValidity(message){ this.validityMessage = message; }});
    return elements.get(id);
}};
const context = vm.createContext({document, setTimeout, clearTimeout});
vm.runInContext(fs.readFileSync(runtime+'/resources/javascripts/canary_create_character.js', 'utf8'), context);
const password = document.getElementById('password1');
const form = fs.readFileSync(runtime+'/resources/view/pages/account/createaccount.html.twig', 'utf8');
for (const name of ['password1', 'password2']) {
    const input = form.match(new RegExp('<input[^>]*name="'+name+'"[^>]*>'))[0];
    const maxlength = Number(input.match(/maxlength="(\d+)"/)[1]);
    assert.ok('\u{1F680}'.repeat(128).length <= maxlength, 'Native maxlength truncates a valid 128-code-point password');
}
for (const count of [12, 128, 129]) {
    password.value='\u{1F680}'.repeat(count); password.input();
    assert.equal(password.validityMessage === '', count <= 128, 'Supplementary Unicode code-point boundary differs');
}
for (const value of ['Valid<&Pass12', 'a password with spaces', 'é'.repeat(128)]) {
    password.value=value; password.input();
    assert.equal(password.validityMessage, '', 'Valid raw password rejected');
}
for (const value of ['short', 'é'.repeat(129), 'Valid\0Pass123']) {
    password.value=value; password.input();
    assert.ok(password.validityMessage, 'Invalid length/NUL accepted');
}
const account = document.getElementById('accname');
account.value='abc'; account.input(); assert.equal(account.validityMessage, '');
account.value='a_b'; account.input(); assert.ok(account.validityMessage);
const world = vm.createContext({document:{}, $:()=>({ready(){}})});
vm.runInContext(fs.readFileSync(runtime+'/resources/javascripts/create_character.js', 'utf8'), world);
vm.runInContext("ServerList.push(['Canary Local','BRA','open',0,0,0,0,'1'])", world);
assert.equal(vm.runInContext("GetServerOptionValue('Canary Local')", world), '1');
console.log('PASS SignupForm.Tests.js (raw passwords, UTF8 lengths, account rules, numeric world)');
