enum Token{
	none,
	inferPrecondition,
	infer,
	errorPr,
	samplePrecondition,
	sample,
	expectation,
	uniformIntPrecondition, // TODO: remove
	uniformInt,
	categoricalPrecondition,
	categorical,
	binomial,
}
private Token computeToken(string s){
	switch(s) with(Token){
		case "(r;f)=>δ_r[∫dy f()[y]]":
		return inferPrecondition;
		case "(r;f)=>δ_r[Λx.f()[x]/∫dy f()[y]]":
			return infer;
		case "(r;d)=>δ_r[∫dx d[x]·(case(x){ val(y) ⇒ 0;⊥ ⇒ 1 })]":
			return errorPr;
		case "(x;p)=>(1-p)·δ[1-x]+p·δ[x]":
			return samplePrecondition;
		case "(r;d,b)=>∫dx d[x]·(case(x){ val(y) ⇒ δ_r[y];⊥ ⇒ 0 })/(1-b)", "(x;d)=>d[x]":
			return sample;
		case "(r;d,b)=>δ[-r+∫dx d[x]·(case(x){ val(y) ⇒ y;⊥ ⇒ 0 })/(1-b)]", "(r;d)=>δ[-r+∫dx d[x]·x]":
			return expectation;
		case "(r;a,b)=>δ[-r+∑_i[a≤i]·[i≤b]]": // uniformInt precondition (TODO: remove)
			return uniformIntPrecondition;
		case "(x;a,b)=>(∑_i[a≤i]·[i≤b]·δ[i-x])·⅟(∑_i[a≤i]·[i≤b])":
			return uniformInt;
		case "(r;p)=>δ[-r+[∑_i[0≤i]·[i<p.length]·[p@[i]<0]=0]·[∑_i[0≤i]·[i<p.length]·p@[i]=1]]":
			return categoricalPrecondition;
		case "(x;p)=>∑_i[0≤i]·[i<p.length]·p@[i]·δ[i-x]":
			return categorical;
		case "(x;n,p)=>∑_ξ₁(-p+1)^(-ξ₁+n)·(∫dξ₂[-ξ₂≤0]·ξ₂^n·⅟e^ξ₂)·[-n+ξ₁≤0]·[-ξ₁≤0]·p^ξ₁·δ[-ξ₁+x]·⅟(∫dξ₂[-ξ₂≤0]·ξ₂^(-ξ₁+n)·⅟e^ξ₂)·⅟(∫dξ₂[-ξ₂≤0]·ξ₂^ξ₁·⅟e^ξ₂)":
			return binomial;
		default:
			return Token.none;
	}	
}
Token getToken(string s){
	static Token[const(char)*] tokens;
	if(auto t=s.ptr in tokens) return *t;
	return tokens[s.ptr]=computeToken(s);
}
