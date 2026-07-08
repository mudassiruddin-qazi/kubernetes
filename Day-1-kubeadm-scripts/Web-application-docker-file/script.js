document
.getElementById("registrationForm")
.addEventListener("submit",function(e){

e.preventDefault();

document.getElementById("message").innerHTML=
"Registration submitted successfully.";

this.reset();

});
