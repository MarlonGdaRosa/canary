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
