import { REVIEWS } from "./data.js";

export const getReviewsById = (reviewId) => REVIEWS.find((it) => it.id === reviewId);
export const getReviewsByProductUpc = (productUpc) => REVIEWS.filter((it) => it.product.upc === productUpc);
export const getReviewsByUserId = (userId) => REVIEWS.filter((it) => it.user.id === userId);

// All product UPCs that appear in reviews — used to populate forYouProducts.
const FOR_YOU_UPCS = [...new Set(REVIEWS.map((r) => r.product.upc))];

export const resolvers = {
  Review: {
    __resolveReference: (ref) => getReviewsById(ref.id),
  },

  Product: {
    reviews: (parent) => getReviewsByProductUpc(parent.upc),

    // Explicit-argument version — client (or a Router Rhai script) passes subscriptionType.
    // Use this path when querying Product directly (e.g. listAllProducts { foryou(...) }).
    // For the @fromContext-powered version, query via User.forYouProducts instead.
    foryou: (parent, { subscriptionType }) => subscriptionType === "DOUBLE",
  },

  User: {
    __resolveReference: (ref) => ({ id: ref.id }),
    reviews: (parent) => getReviewsByUserId(parent.id),

    // Returns the set of products reviewed in this subgraph as the personalised feed.
    // In production this would be a ranked/filtered list from a recommendation service.
    forYouProducts: () => FOR_YOU_UPCS.map((upc) => ({ upc, product: { upc } })),
  },

  ForYouProduct: {
    // Entity resolution: the Router re-fetches ForYouProduct by its upc key when needed.
    __resolveReference: (ref) => ({ upc: ref.upc, product: { upc: ref.upc } }),

    product: (parent) => ({ upc: parent.upc }),

    // subscriptionType is injected by the Router via @fromContext(field: "$userContext { subscriptionType }").
    // The client never sends this argument; the Router inlines it into the subgraph
    // query document, which is why SINGLE and DOUBLE users produce different
    // query-hash segments in the Redis cache key for the same product entity.
    foryou: (parent, { subscriptionType }) => subscriptionType === "DOUBLE",
  },
};
